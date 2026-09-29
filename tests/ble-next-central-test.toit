// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// The experimental application API in the central role: connect, discovery,
// reads, writes, subscriptions (scoped and not), PHY and parameter requests, RSSI, and the
// reason of a local disconnect.

import expect show *
import monitor
import ble.experimental.next as ble
import ble.experimental.transport
import ble.experimental.service.gatt-provider as providers
import .ble-fixture as fixture

main:
  with-timeout --ms=10_000:
    provider := Provider
    provider.install
    ended := monitor.Latch
    responder := task::
      try:
        radio := provider.radio
        fixture.initialize-replies radio
        fixture.status-reply radio fixture.create-command
        radio.received.add fixture.connection-event
        fixture.gatt-reply radio #[2, 247, 0] #[3, 247, 0]
        // Services twice (fff0, then the missing fff9), then the characteristics of fff0.
        2.repeat:
          fixture.gatt-reply radio #[0x10, 1, 0, 255, 255, 0, 0x28] #[0x11, 6, 1, 0, 5, 0, 0xf0, 0xff]
          fixture.gatt-reply radio #[0x10, 6, 0, 255, 255, 0, 0x28] #[1, 0x10, 6, 0, 0x0a]
        fixture.gatt-reply radio #[8, 1, 0, 5, 0, 3, 0x28] #[9, 7, 2, 0, 0x1e, 3, 0, 0xf1, 0xff]
        fixture.gatt-reply radio #[8, 3, 0, 5, 0, 3, 0x28] #[1, 8, 3, 0, 0x0a]
        fixture.gatt-reply radio #[0x0a, 3, 0] #[0x0b, 42]
        fixture.gatt-reply radio #[0x0a, 3, 0] #[1, 0x0a, 3, 0, 5]
        fixture.gatt-reply radio #[0x12, 3, 0, 43] #[0x13]
        fixture.att-sent radio #[0x52, 3, 0, 44]
        // Subscribe: find the CCCD, enable, two values, disable.
        fixture.gatt-reply radio #[4, 4, 0, 5, 0] #[5, 1, 4, 0, 2, 0x29]
        fixture.gatt-reply radio #[4, 5, 0, 5, 0] #[1, 4, 5, 0, 0x0a]
        fixture.gatt-reply radio #[0x12, 4, 0, 1, 0] #[0x13]
        radio.received.add (fixture.att-event #[0x1b, 3, 0, 7])
        radio.received.add (fixture.att-event #[0x1b, 3, 0, 8])
        fixture.gatt-reply radio #[0x12, 4, 0, 0, 0] #[0x13]
        // The same through a Subscription object.
        fixture.gatt-reply radio #[4, 4, 0, 5, 0] #[5, 1, 4, 0, 2, 0x29]
        fixture.gatt-reply radio #[4, 5, 0, 5, 0] #[1, 4, 5, 0, 0x0a]
        fixture.gatt-reply radio #[0x12, 4, 0, 1, 0] #[0x13]
        radio.received.add (fixture.att-event #[0x1b, 3, 0, 9])
        radio.received.add (fixture.att-event #[0x1b, 3, 0, 10])
        fixture.gatt-reply radio #[0x12, 4, 0, 0, 0] #[0x13]
        // Read Multiple Variable Length, then Read By Type and includes.
        fixture.gatt-reply radio #[0x20, 3, 0, 3, 0] #[0x21, 1, 0, 42, 1, 0, 43]
        fixture.gatt-reply radio #[8, 1, 0, 5, 0, 0xf1, 0xff] #[9, 3, 3, 0, 42]
        fixture.gatt-reply radio #[8, 4, 0, 5, 0, 0xf1, 0xff] #[1, 8, 4, 0, 0x0a]
        fixture.gatt-reply radio #[8, 1, 0, 5, 0, 2, 0x28] #[1, 8, 1, 0, 0x0a]
        fixture.status-reply radio #[1, 0x32, 0x20, 7, 0x34, 2, 0, 2, 2, 0, 0]
        radio.received.add #[4, 0x3e, 6, 0x0c, 0, 0x34, 2, 2, 2]
        fixture.reply radio #[1, 0x05, 0x14, 2, 0x34, 2] #[0x34, 2, 0xc4]
        fixture.reply radio #[1, 0x2d, 0x0c, 3, 0x34, 2, 0] #[0x34, 2, 3]
        fixture.status-reply radio #[1, 0x13, 0x20, 14, 0x34, 2, 24, 0, 24, 0, 0, 0, 0x90, 1, 0, 0, 0, 0]
        radio.received.add #[4, 0x3e, 10, 3, 0, 0x34, 2, 24, 0, 0, 0, 0x90, 1]
        fixture.status-reply radio #[1, 6, 4, 3, 0x34, 2, 0x13]
        radio.received.add #[4, 5, 4, 0, 0x34, 2, 0x16]
      finally:
        critical-do --no-respect-deadline: ended.set true
    adapter := ble.Adapter
    try:
      expect adapter.capabilities.central
      peer := ble.Address #[1, 2, 3, 4, 5, 6] --type=ble.Address.RANDOM
      adapter.with-connection peer: | connection/ble.Connection |
        expect-equals ble.ROLE-CENTRAL connection.role
        expect-equals peer connection.peer
        expect-equals 247 connection.mtu
        expect-equals 6 adapter.address.bytes.size
        expect (not adapter.supports-tx-power-control)
        expect-null adapter.tx-power
        expect-throw "BLE_UNSUPPORTED": adapter.set-tx-power 0
        service := connection.discover-service (ble.BleUuid "fff0")
        expect-equals (ble.BleUuid "fff0") service.uuid
        expect-throw "BLE_SERVICE_NOT_FOUND": connection.discover-service (ble.BleUuid "fff9")
        characteristic := service.characteristic (ble.BleUuid "fff1")
        expect characteristic.can-read
        expect characteristic.can-notify
        expect characteristic.can-write-without-response
        expect-equals #[42] characteristic.read
        error := catch: characteristic.read
        expect error is ble.AttError
        expect-equals ble.AttError.INSUFFICIENT-AUTHENTICATION error.code
        characteristic.write #[43]
        characteristic.write #[44] --no-response
        values := []
        characteristic.subscribe: | stream/ble.Values |
          values.add stream.receive
          values.add stream.receive
        expect-equals [#[7], #[8]] values
        subscription := characteristic.subscribe
        received := monitor.Latch
        task:: received.set subscription.receive
        expect-equals #[9] received.get
        expect-equals #[10] subscription.receive
        expect (not subscription.is-closed)
        subscription.close
        expect subscription.is-closed
        expect-throw "BLE_CLOSED": subscription.receive
        expect-equals [#[42], #[43]] (connection.read-multiple [characteristic, characteristic])
        expect-equals [#[42]] (service.read-by-uuid (ble.BleUuid "fff1"))
        expect-equals [] service.discover-included-services
        expect-equals (ble.Phy ble.PHY-2M ble.PHY-2M) (connection.request-phy ble.PHY-2M)
        expect-equals (ble.Phy ble.PHY-2M ble.PHY-2M) connection.phy
        expect-equals -60 connection.rssi
        expect-equals 3 connection.tx-power
        parameters := connection.request-parameters --interval-min=(Duration --ms=30)
        expect-equals (Duration --ms=30) parameters.interval
        expect-equals (Duration --s=4) parameters.supervision-timeout
        connection.disconnect
        expect connection.is-closed
        expect-equals ble.DisconnectReason.LOCAL-HOST connection.wait-closed.code
      ended.get
    finally:
      adapter.close
      responder.cancel
      provider.uninstall

class Provider extends providers.Provider:
  radio/fixture.FakeTransport := fixture.FakeTransport
  constructor: super
  open-transport -> transport.Transport: return radio
