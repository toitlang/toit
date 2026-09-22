// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.central
import ble.experimental.connection
import ble.experimental.extended-central as extended
import ble.experimental.hci
import ble.experimental.service.client as clients
import ble.experimental.service.provider as rpc
import expect show *
import monitor
import .ble-hci-test as fixture
import .ble-multilink-test as links
import .ble-service-multiclient-test as services

main:
  with-timeout --ms=20_000:
    [false, true].do: | configuring/bool |
      ["cancel", "deadline", "rejected", "missing"].do:
        interrupted configuring it
    interrupted false "won"
    interrupted false "missing-completion"
    interrupted false "failed-cancel"
    service-close false
    service-close true

// Holds Command Status until the provider has closed the second client's
// resource. That closure cancels the worker while it still owns the command.
service-close won/bool:
  provider := Provider
  provider.install
  first := clients.Client
  second := clients.Client
  first.open
  second.open
  seen := monitor.Latch
  ended := monitor.Latch
  done := monitor.Latch
  returned := false
  caller/Task? := null
  responder := task::
    radio := provider.radio
    fixture.initialize-replies radio
    links.establish radio 1 0x234
    expect-equals (hci.command-packet 0x200d (connection.create-parameters (links.address 2) --address-type=1)) radio.sent.take
    seen.set true
    while not provider.last.is-closed: yield
    radio.received.add #[4, 15, 4, 0, 1, 0x0d, 0x20]
    fixture.reply radio #[1, 0x0e, 0x20, 0] #[]
    event := links.connected 2 0x235
    if not won: event[4] = 2
    radio.received.add event
    if won: services.disconnect radio 0x235
    services.sent radio 0x234 #[0x0a, 3, 0]
    services.incoming radio 0x234 #[0x0b, 44]
    services.disconnect radio 0x234
    done.set true
  try:
    survivor := first.connect (links.address 1) --address-type=1
    caller = task::
      try:
        catch:
          second.connect (links.address 2) --address-type=1
          returned = true
      finally:
        critical-do --no-respect-deadline: ended.set true
    seen.get
    second.close
    ended.get
    expect (not returned)
    expect-equals #[44] (survivor.read 3)
    expect (not provider.radio.closed)
    survivor.disconnect
    done.get
    while not provider.radio.closed: yield
    expect-equals 1 provider.opens
  finally:
    if caller: caller.cancel
    responder.cancel
    first.close
    second.close
    provider.uninstall

class Provider extends services.Provider:
  last/rpc.Session? := null

  constructor: super

  create-connection client/int arguments/List -> rpc.Session:
    last = super client arguments
    return last

// Holds a configuration reply or Create Connection status while the caller
// leaves. Successful cleanup must preserve traffic and allow slot/handle reuse.
interrupted configuring/bool mode/string --extended-mode/bool=false:
  radio := fixture.FakeTransport
  controller := hci.Controller radio
  host := extended-mode
      ? (extended.Central controller --link-limit=2 --acl-count=2)
      : (central.Central controller --link-limit=2 --acl-count=2)
  seen := monitor.Latch
  release := monitor.Latch
  ended := monitor.Latch
  done := monitor.Latch
  returned := false
  failure := null
  terminal := mode == "missing" or mode == "deadline" or mode == "missing-completion" or mode == "failed-cancel"
  waiter/Task? := null
  responder := task::
    establish radio host 1 0x234 --extended-mode=extended-mode
    expected := configuring
        ? (hci.command-packet 0x2005 #[1, 2, 3, 4, 5, 0xc6])
        : (hci.command-packet host.connection-opcode (host.encode-connection (links.address 2) --address-type=1 --own-address-type=0))
    expect-equals expected radio.sent.take
    seen.set true
    release.get
    if mode != "missing" and mode != "deadline":
      status := mode == "rejected" ? 0x0c : 0
      if configuring: radio.received.add #[4, 14, 4, 1, 5, 0x20, status]
      else: radio.received.add #[4, 15, 4, status, 1, host.connection-opcode & 0xff, 0x20]
      if not configuring and status == 0:
        expect-equals #[1, 0x0e, 0x20, 0] radio.sent.take
        radio.received.add #[4, 14, 4, 1, 0x0e, 0x20, mode == "failed-cancel" ? 0x12 : 0]
        if mode != "missing-completion" and mode != "failed-cancel":
          event := completed-connection 2 0x235 --extended-mode=extended-mode
          if mode != "won": event[4] = 2
          radio.received.add event
          if mode == "won":
            fixture.status-reply radio #[1, 6, 4, 3, 0x35, 2, 0x13]
            links.ended radio 0x235
    ended.get
    if not terminal:
      links.incoming radio 0x234 #[1, 0, 4, 0, 0xa1] --start
      expect-equals #[2, 0x34, 2, 5, 0, 1, 0, 4, 0, 0xa2] radio.sent.take
      links.completed radio 0x234
      establish radio host 3 0x235 --extended-mode=extended-mode
      links.incoming radio 0x235 #[1, 0, 4, 0, 0xb1] --start
    done.set true
  try:
    survivor := host.connect (links.address 1) --address-type=1
    waiter = task::
      try:
        failure = catch:
          host.connect (links.address 2) --address-type=1
              --local-random-address=(configuring ? #[1, 2, 3, 4, 5, 0xc6] : null)
              --timeout=(Duration --ms=(mode == "deadline" ? 40 : 200))
          returned = true
      finally:
        critical-do --no-respect-deadline: ended.set true
    seen.get
    if mode == "deadline": sleep --ms=60
    else: waiter.cancel
    yield
    // A delayed reply remains owned until it is consumed or its own bound ends.
    if mode != "deadline": expect (not ended.has-value)
    release.set true
    with-timeout --ms=4_000: ended.get
    expect (not returned)
    if mode == "deadline": expect-equals DEADLINE-EXCEEDED-ERROR failure
    if terminal:
      // Deadline expiry before the command reply is inherently ambiguous.
      expect (radio.closed and not survivor.connected)
    else:
      expect (survivor.connected and not radio.closed)
      expect-equals #[0xa1] survivor.receive.payload
      host.send survivor 4 #[0xa2]
      replacement := host.connect (links.address 3) --address-type=1
      expect-equals #[0xb1] replacement.receive.payload
      expect (replacement.connected and survivor.connected)
    done.get
  finally:
    if waiter: waiter.cancel
    responder.cancel
    host.close
    host.wait-closed

establish radio/fixture.FakeTransport host/central.Central peer/int handle/int --extended-mode/bool:
  fixture.status-reply radio
      hci.command-packet host.connection-opcode (host.encode-connection (links.address peer) --address-type=1 --own-address-type=0)
  radio.received.add (completed-connection peer handle --extended-mode=extended-mode)

completed-connection peer/int handle/int --extended-mode/bool=true -> ByteArray:
  event := links.connected peer handle
  if not extended-mode: return event
  enhanced := event[..15] + (ByteArray 12) + event[15..]
  enhanced[2] = 31
  enhanced[3] = 0x0a
  return enhanced
