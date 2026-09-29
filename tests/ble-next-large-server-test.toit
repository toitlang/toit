// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// A GATT server larger than the provider's default 64 attributes: the
// application API asks for a database of the size its definition needs.

import expect show *
import monitor
import ble.experimental.next as ble
import .ble-fixture as fixture
import .ble-next-peripheral-test as peripheral

COUNT ::= 40

main:
  with-timeout --ms=10_000:
    provider := peripheral.Provider
    provider.install
    ended := monitor.Latch
    responder := task::
      try:
        radio := provider.radios.receive
        fixture.initialize-replies radio
        peripheral.accept radio
        // Nine default attributes, the service at 10, then two per
        // characteristic: the last value is at 10 + 2 * COUNT.
        last := 10 + 2 * COUNT
        radio.received.add (fixture.att-event #[0x0a, last, 0])
        fixture.att-sent radio #[0x0b, COUNT - 1]
        radio.received.add #[4, 5, 4, 0, 0x34, 2, 0x13]
      finally:
        critical-do --no-respect-deadline: ended.set true
    adapter := ble.Adapter
    try:
      server := ble.GattServer
      service := server.add-service (ble.BleUuid "fff0")
      COUNT.repeat: | index/int |
        service.add-characteristic (ble.BleUuid "$(%04x 0xf000 + index)") --read --value=#[index]
      peripheral-role := adapter.peripheral server --advertisement=peripheral.ADVERTISEMENT
      connection := peripheral-role.accept
      expect-equals ble.DisconnectReason.REMOTE-USER connection.wait-closed.code
      connection.close
      peripheral-role.close
      ended.get
    finally:
      adapter.close
      responder.cancel
      provider.uninstall
