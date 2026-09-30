// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Three peripherals at once through the application API on a provider with a
// central session limit of three: each connection is its own session, the
// fourth waits for a slot, and a released slot is reused.

import expect show *
import monitor
import ble.v2 as ble
import ble.experimental.transport
import ble.experimental.service.gatt-provider as providers
import .ble-fixture as fixture
import .ble-multilink-test as links
import .ble-service-multiclient-test as wire

HANDLES ::= [0x234, 0x235, 0x236]

main:
  with-timeout --ms=10_000:
    provider := Provider
    provider.install
    first-reads := monitor.Latch
    released := monitor.Latch
    ended := monitor.Latch
    responder := task::
      try:
        radio := provider.radio
        fixture.initialize-replies radio
        3.repeat: links.establish radio (it + 1) HANDLES[it]
        // Reads are answered out of order: each link waits only for its own.
        3.repeat: wire.sent radio HANDLES[it] #[0x0a, 3, 0]
        [2, 0, 1].do: wire.incoming radio HANDLES[it] #[0x0b, 10 + it]
        first-reads.set true
        wire.disconnect radio HANDLES[1]
        released.get
        // The fourth peripheral gets the released slot and handle.
        links.establish radio 4 HANDLES[1]
        wire.sent radio HANDLES[1] #[0x0a, 3, 0]
        wire.incoming radio HANDLES[1] #[0x0b, 40]
        [HANDLES[0], HANDLES[1], HANDLES[2]].do: wire.disconnect radio it
      finally:
        critical-do --no-respect-deadline: ended.set true
    adapter := ble.Adapter
    try:
      expect-equals 3 adapter.capabilities.max-sessions
      connections := List 3: adapter.connect (address (it + 1)) --mtu=23
      values := List 3
      readers := List 3: | index/int |
        task:: values[index] = read connections[index]
      first-reads.get
      readers.do: | reader/Task | while values.contains null: sleep --ms=1
      expect-equals [#[10], #[11], #[12]] values
      // A fourth connection is refused while all three slots are in use.
      expect-throw "GATT_SERVICE_BUSY": adapter.connect (address 4) --mtu=23
      connections[1].disconnect
      connections[1].close
      released.set true
      fourth := adapter.connect (address 4) --mtu=23
      expect-equals #[40] (read fourth)
      [connections[0], fourth, connections[2]].do: | connection/ble.Connection |
        connection.disconnect
        connection.close
      ended.get
    finally:
      adapter.close
      responder.cancel
      provider.uninstall

address peer/int -> ble.Address:
  return ble.Address (links.address peer) --type=ble.Address.RANDOM

/** Reads handle 3 without discovery, as a known-layout client would. */
read connection/ble.Connection -> ByteArray:
  return connection.central_.read 3

class Provider extends providers.Provider:
  radio/fixture.FakeTransport := fixture.FakeTransport
  constructor: super
  central-session-limit -> int: return 3
  open-transport -> transport.Transport: return radio
