// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// The application API as a peripheral that reads the connected central's
// database: discovery, a read and a subscription over the same link.

import expect show *
import monitor
import ble.v2 as ble
import .ble-fixture as fixture
import .ble-next-peripheral-test as peripheral
import .ble-peripheral-client-test as peer-fixture

main:
  with-timeout --ms=10_000:
    provider := peripheral.Provider
    provider.install
    ended := monitor.Latch
    peer := peer-fixture.Peer
    unsubscribed := monitor.Latch
    responder := task::
      try:
        radio := provider.radios.receive
        fixture.initialize-replies radio
        peripheral.accept radio
        while true:
          request := peer.answer radio
          if request[0] == 0x12 and request[3] == 1:
            peer.database.set-value peer.level #[78]
            radio.received.add (fixture.att-event (peer.session.notification peer.level))
            break
        expect-equals #[0x12, peer.level + 1, 0, 0, 0] (peer.answer radio)
        unsubscribed.get
        radio.received.add #[4, 5, 4, 0, 0x34, 2, 0x13]
      finally:
        critical-do --no-respect-deadline: ended.set true
    adapter := ble.Adapter
    try:
      server := ble.GattServer
      (server.add-service (ble.BleUuid "fff0")).add-characteristic (ble.BleUuid "fff1") --read --value=#[1]
      role := adapter.peripheral server --advertisement=peripheral.ADVERTISEMENT
      connection := role.accept
      battery := connection.discover-service (ble.BleUuid "180f")
      level := battery.characteristic (ble.BleUuid "2a19")
      expect-equals #[77] level.read
      level.subscribe: | values/ble.Values |
        expect-equals #[78] values.receive
      unsubscribed.set true
      expect-equals ble.DisconnectReason.REMOTE-USER connection.wait-closed.code
      connection.close
      role.close
      ended.get
    finally:
      adapter.close
      responder.cancel
      provider.uninstall
