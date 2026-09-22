// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor
import ble.experimental.hci
import ble.experimental.transport
import ble.experimental.service.api as api
import ble.experimental.service.client as clients
import ble.experimental.service.central-provider as central
import ble.experimental.service.gatt-provider as providers
import ble.experimental.service.provider as rpc
import .ble-hci-test as fixture
import .ble-multilink-test as links
import .ble-service-multiclient-test as shared

EXIT-WHEN-READY ::= 1000

main:
  run: spawn:: application

run [start-application]:
  with-timeout --ms=10_000:
    provider := Provider
    provider.install
    survivor := clients.Client
    replacement := clients.Client
    survivor.open
    replacement.open
    disconnecting := monitor.Latch
    responder := task::
      radio := provider.radio
      fixture.initialize-replies radio
      links.establish radio 1 0x234
      shared.sent radio 0x234 #[0x12, 4, 0, 1, 0]
      shared.incoming radio 0x234 #[0x13]
      links.establish radio 2 0x235
      fixture.status-reply radio #[1, 6, 4, 3, 0x34, 2, 0x13]
      disconnecting.set true
      // Hold A's physical disconnect while B continues its ATT exchange.
      shared.sent radio 0x235 #[0x0a, 3, 0]
      shared.incoming radio 0x235 #[0x0b, 22]
      provider.complete-disconnect.get
      links.ended radio 0x234
      links.establish radio 3 0x234
      shared.sent radio 0x235 #[0x0a, 3, 0]
      shared.incoming radio 0x235 #[0x0b, 23]
      shared.disconnect radio 0x234
      shared.disconnect radio 0x235
    try:
      start-application.call
      while not provider.exiting: sleep --ms=1
      provider.exiting.entered.get
      b := survivor.connect (links.address 2) --address-type=1
      provider.allow-exit.set true
      disconnecting.get
      expect provider.exiting.closed-with-waiter
      provider.exiting.wait-ended.get
      expect (not provider.exiting.is-released)
      expect-throw "GATT_SERVICE_BUSY": replacement.connect (links.address 3) --address-type=1
      expect-equals #[22] (b.read 3)
      expect (not provider.radio.closed)
      provider.complete-disconnect.set true
      while not provider.exiting.is-released: sleep --ms=1
      c := replacement.connect (links.address 3) --address-type=1
      expect-equals #[23] (b.read 3)
      c.disconnect
      expect (not provider.radio.closed)
      b.disconnect
      expect provider.radio.closed
      expect-equals 1 provider.opens
    finally:
      provider.allow-exit.set true
      provider.complete-disconnect.set true
      survivor.close
      replacement.close
      responder.cancel
      provider.uninstall

application --oom/bool=false:
  client := ExitClient
  client.open
  connection := client.connect (links.address 1) --address-type=1
  connection.subscribe 3 --cccd=4: | stream |
    task:: stream.receive
    client.exit-when-ready
    if oom:
      // Die in a background task while application cleanup remains suspended.
      task::
        set-max-heap-size_ (256 * 1024)
        ballast := []
        while true: ballast.add (ByteArray 128 --initial=42)
      (monitor.Latch).get
    // The process terminates without running application cleanup blocks.
    exit 0

class ExitClient extends clients.Client:
  constructor:
    super
  exit-when-ready -> none: invoke_ EXIT-WHEN-READY null

class Provider extends providers.Provider:
  radio/fixture.FakeTransport ::= fixture.FakeTransport
  exiting/Session? := null
  allow-exit/monitor.Latch ::= monitor.Latch
  complete-disconnect/monitor.Latch ::= monitor.Latch
  opens/int := 0

  constructor:
    super
  central-session-limit -> int: return 2
  open-transport -> transport.Transport:
    opens++
    return radio
  create-connection client/int arguments/List -> rpc.Session:
    if arguments[0][0] != 1: return super client arguments
    exiting = Session this client arguments[0] arguments[1] arguments[2] arguments[3]
    return exiting
  handle index/int arguments/any --gid/int --client/int -> any:
    if index == EXIT-WHEN-READY:
      exiting.entered.get
      allow-exit.get
      return null
    return super index arguments --gid=gid --client=client

class Session extends central.ConnectionSession:
  entered/monitor.Latch ::= monitor.Latch
  wait-ended/monitor.Latch ::= monitor.Latch
  waiting/bool := false
  closed-with-waiter/bool := false

  constructor provider/Provider client/int address/ByteArray type/int timeout/int mtu/int:
    super provider client address type timeout mtu
  invoke index/int arguments/List -> any:
    if index != api.CENTRAL-SUBSCRIPTION-NEXT: return super index arguments
    waiting = true
    entered.set true
    try:
      return super index arguments
    finally:
      critical-do --no-respect-deadline:
        waiting = false
        wait-ended.set true
  on-closed -> none:
    closed-with-waiter = waiting
    super
