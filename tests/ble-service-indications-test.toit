// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.transport
import ble.experimental.signaling
import ble.experimental.service.client as clients
import ble.experimental.service.gatt-provider as providers
import ble.experimental.service.provider as rpc
import ble.experimental.service.api as api
import expect show *
import monitor
import system
import .ble-fixture as fixture
import .ble-key-reply-test as keys
import .ble-mtu-server-test as wire

main:
  with-timeout --ms=10_000:
    ["confirmed", "disconnect", "timeout", "client-exit"].do: run it

run mode/string:
  provider := Provider
  ended := monitor.Latch
  responder := task::
    try:
      radio := provider.radio
      fixture.initialize-replies radio --acl-length=27
      keys.establish radio
      fixture.att-sent radio (signaling.parameter-request 1) --channel=5
      radio.received.add (fixture.att-event #[0x13, 1, 2, 0, 0, 0] --channel=5)
      radio.received.add (fixture.att-event #[0x12, 13, 0, 2, 0])
      wire.outgoing radio #[0x13]
      radio.received.add (fixture.att-event (wire.exchange 2 517))
      wire.outgoing radio (wire.exchange 3 517)
      radio.received.add (fixture.att-event #[0x12, 13, 0, 2, 0])
      wire.outgoing radio #[0x13]
      wire.outgoing radio (#[0x1d, 12, 0] + (payload 0))
      if mode == "confirmed":
        // Let the first waiter expire without retracting the submitted indication.
        sleep --ms=50
        radio.received.add (fixture.att-event #[0x1e])
        wire.outgoing radio (#[0x1d, 12, 0] + (payload 1))
        radio.received.add (fixture.att-event #[0x1e])
      if mode == "disconnect":
        sleep --ms=50
        radio.received.add #[4, 5, 4, 0, 0x34, 2, 0x13]
      if mode != "timeout":
        // Await application cleanup, including abrupt process exit.
        while not radio.closed: sleep --ms=1
    finally:
      critical-do --no-respect-deadline: ended.set true
  provider.install
  try:
    spawn:: application mode
    if mode == "client-exit":
      // Process exit must release the outstanding receipt and its controller.
      while not provider.radio.closed: sleep --ms=1
      while not provider.last.is-released: sleep --ms=1
      expect provider.last.closed-with-waiter
      while provider.last.waiting: sleep --ms=1
      expect provider.last.wait-ended
      replacement := clients.Client
      replacement.open
      try:
        next := replacement.configure
        next.close
      finally:
        replacement.close
    provider.uninstall --wait
    if mode == "timeout": responder.cancel
    else: ended.get
    expect provider.radio.closed
  finally:
    responder.cancel
    provider.uninstall

payload seed/int -> ByteArray: return ByteArray 512: (it + seed) % 251

application mode/string:
  client := clients.Client
  client.open
  try:
    session := client.configure --value-limit=512 --mtu-limit=517
    session.add-service #[0xf0, 0xff]
    session.add-characteristic #[0xf1, 0xff] --indicate --value=(payload 0)
    session.start #[2, 1, 6]
    session.peer
    receipt-ready := monitor.Latch
    serving-ended := monitor.Latch
    serving := task::
      try:
        error := catch: session.serve
            (: | request/clients.Request | unreachable)
            (: | request/clients.Request | unreachable)
            (: | handle/int value/ByteArray |
              expect-equals 13 handle
              if session.mtu == 23:
                expect-throw "GATT_VALUE_EXCEEDS_MTU": session.indicate 12
              else:
                receipt := session.indicate 12 --timeout=(Duration --ms=(mode == "timeout" ? 150 : 3_000))
                expect (receipt != null)
                expect-throw "GATT_INDICATION_WAIT_IN_SERVE": receipt.wait
                expect-throw "GATT_INDICATION_BUSY": session.indicate 12
                receipt-ready.set receipt)
        if error and error != "GATT_REQUESTS_CLOSED" and error != "GATT_SERVER_CLOSED": throw error
      finally:
        critical-do --no-respect-deadline: serving-ended.set true
    try:
      receipt/clients.Indication := receipt-ready.get
      if mode == "client-exit":
        // Exit the whole application while the receipt RPC is waiting. No local
        // finally or explicit close is allowed to provide the cleanup proof.
        task::
          sleep --ms=10
          exit 0
        receipt.wait
        throw "UNEXPECTED_CONFIRMATION"
      if mode == "confirmed":
        expect-throw "DEADLINE_EXCEEDED":
          with-timeout --ms=1: receipt.wait
        session.set-value 12 (payload 1)
        system.process-stats --gc
        receipt.wait
        expect-throw "GATT_INDICATION_EXPIRED": receipt.wait
        next := session.indicate 12
        expect-throw "GATT_INDICATION_EXPIRED": receipt.wait
        next.wait
      else if mode == "timeout":
        expect-throw "GATT_INDICATION_TIMEOUT": receipt.wait
      else:
        expect-throw "GATT_SERVER_CLOSED": receipt.wait
    finally:
      client.close
      serving.cancel
      critical-do --no-respect-deadline: serving-ended.get
  finally:
    client.close

class Provider extends providers.Provider:
  radio/fixture.FakeTransport ::= fixture.FakeTransport
  last/ObservedSession? := null
  constructor:
    super
  create-bounded-builder client/int name/string value-limit/int mtu-limit/int
      --attribute-limit/int=64 -> rpc.Session:
    last = ObservedSession this client --name=name --value-limit=value-limit --mtu-limit=mtu-limit
    return last
  open-transport -> transport.Transport: return radio

class ObservedSession extends providers.Session:
  waiting/bool := false
  wait-ended/bool := false
  closed-with-waiter/bool := false

  constructor provider/providers.Provider client/int --name/string --value-limit/int --mtu-limit/int:
    super provider client --name=name --value-limit=value-limit --mtu-limit=mtu-limit

  invoke index/int arguments/List -> any:
    if index != api.WAIT-INDICATION: return super index arguments
    waiting = true
    try:
      return super index arguments
    finally:
      waiting = false
      wait-ended = true

  on-closed -> none:
    closed-with-waiter = waiting
    super
