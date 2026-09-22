// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor
import ble.experimental.transport
import ble.experimental.service.client as clients
import ble.experimental.service.gatt-provider as providers
import ble.experimental.service.provider as rpc
import .ble-hci-test as fixture
import .ble-multilink-test as links
import .ble-service-multiclient-test as shared
import .ble-service-central-cancel-test as shutdown

main:
  failure-recovery
  closing-admission

failure-recovery:
  with-timeout --ms=10_000:
    provider := Provider
    provider.install
    first := clients.Client
    second := clients.Client
    replacement := clients.Client
    first.open
    second.open
    replacement.open
    first-ended := monitor.Latch
    second-ended := monitor.Latch
    first-request := monitor.Latch
    responder := task::
      radio := provider.failed
      fixture.initialize-replies radio
      links.establish radio 1 0x234
      links.establish radio 2 0x235
      shared.sent radio 0x234 #[0x0a, 3, 0]
      first-request.set true
      shared.sent radio 0x235 #[0x0a, 3, 0]
      radio.close
      fixture.initialize-replies provider.fresh
      links.establish provider.fresh 3 0x234
      shared.sent provider.fresh 0x234 #[0x0a, 3, 0]
      shared.incoming provider.fresh 0x234 #[0x0b, 33]
      shared.disconnect provider.fresh 0x234
    readers := []
    try:
      a := first.connect (links.address 1) --address-type=1
      b := second.connect (links.address 2) --address-type=1
      readers.add (task:: first-ended.set (catch: a.read 3))
      first-request.get
      readers.add (task:: second-ended.set (catch: b.read 3))
      expect-equals "FAKE_CLOSED" first-ended.get
      expect-equals "FAKE_CLOSED" second-ended.get
      expect-throw "GATT_SERVICE_BUSY": replacement.connect (links.address 3) --address-type=1
      expect-equals 1 provider.opens
      first.close
      second.close
      with-timeout --ms=1000:
        while provider.sessions.any (: | session/rpc.Session | not session.is-released):
          sleep --ms=1
      replacement.with-connection (links.address 3) --address-type=1: | c |
        expect-equals #[33] (c.read 3)
      expect-equals 2 provider.opens
      expect provider.fresh.closed
    finally:
      readers.do: it.cancel
      first.close
      second.close
      replacement.close
      responder.cancel
      provider.uninstall

class Provider extends providers.Provider:
  failed/fixture.FakeTransport
  fresh/fixture.FakeTransport ::= fixture.FakeTransport
  sessions/List ::= []
  opens/int := 0

  constructor --delayed/bool=false:
    failed = delayed ? shutdown.DelayedTransport : fixture.FakeTransport
    super
  central-session-limit -> int: return 2
  open-transport -> transport.Transport:
    opens++
    expect (opens <= 2)
    return opens == 1 ? failed : fresh
  create-connection client/int arguments/List -> rpc.Session:
    result := super client arguments
    sessions.add result
    return result

// Reaching zero reservations starts controller teardown. A new reservation must
// not attach to that pool while its transport reader is still being joined.
closing-admission:
  with-timeout --ms=10_000:
    provider := Provider --delayed
    provider.install
    first := clients.Client
    replacement := clients.Client
    first.open
    replacement.open
    radio := provider.failed as shutdown.DelayedTransport
    done := monitor.Latch
    responder := task::
      fixture.initialize-replies radio
      links.establish radio 1 0x234
      shared.disconnect radio 0x234
      fixture.initialize-replies provider.fresh
      links.establish provider.fresh 3 0x234
      shared.disconnect provider.fresh 0x234
    caller/Task? := null
    try:
      a := first.connect (links.address 1) --address-type=1
      radio.hold = true
      caller = task::
        error := catch: a.disconnect
        done.set error
      radio.closing.get
      expect-throw "GATT_SERVICE_BUSY": replacement.connect (links.address 3) --address-type=1
      expect-equals 1 provider.opens
      radio.release.set true
      expect-equals null done.get
      replacement.with-connection (links.address 3) --address-type=1: null
      expect-equals 2 provider.opens
      expect provider.fresh.closed
    finally:
      radio.release.set true
      if caller: caller.cancel
      first.close
      replacement.close
      responder.cancel
      provider.uninstall
