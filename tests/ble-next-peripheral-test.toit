// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// The experimental application API in the peripheral role: accept (the
// connect event), handlers, notifications, link details and the disconnect
// reason, then a second central.

import expect show *
import monitor
import ble.experimental.next as ble
import ble.experimental.advertising-set
import ble.experimental.signaling as signaling
import ble.experimental.transport
import ble.experimental.service.gatt-provider as providers
import .ble-fixture as fixture
import .ble-peripheral-test as peripheral-fixture

// Handles: the default database ends at 13, the service is 14.
STATIC ::= 16
DYNAMIC ::= 18
CONTROL ::= 20
DATA ::= 22
DATA-CCCD ::= 23

ADVERTISEMENT ::= ble.Advertisement --name="T"
// The API adds the Flags field to connectable advertising.
RAW-ADVERTISEMENT ::= #[2, 1, 6, 2, 9, 0x54]

main:
  with-timeout --ms=10_000:
    provider := Provider
    provider.install
    disconnect := monitor.Latch
    subscribed := monitor.Latch
    ended := monitor.Latch
    responder := task::
      try:
        radio := provider.radios.receive
        fixture.initialize-replies radio
        accept radio
        radio.received.add (fixture.att-event #[0x0a, STATIC, 0])
        fixture.att-sent radio #[0x0b, 1]
        radio.received.add (fixture.att-event #[0x0a, DYNAMIC, 0])
        fixture.att-sent radio #[0x0b, 0x42]
        // The validator refuses 0 with Value Not Allowed.
        radio.received.add (fixture.att-event #[0x12, CONTROL, 0, 0])
        fixture.att-sent radio #[0x01, 0x12, CONTROL, 0, 0x13]
        radio.received.add (fixture.att-event #[0x12, CONTROL, 0, 7])
        fixture.att-sent radio #[0x13]
        radio.received.add (fixture.att-event #[0x12, DATA-CCCD, 0, 1, 0])
        fixture.att-sent radio #[0x13]
        subscribed.set true
        fixture.att-sent radio #[0x1b, DATA, 0, 5]
        fixture.att-sent radio #[0x1b, DATA, 0, 6]
        fixture.reply radio #[1, 0x05, 0x14, 2, 0x34, 2] #[0x34, 2, 0xc4]
        // The peripheral asks for 30 ms through L2CAP; the central accepts and applies it.
        fixture.att-sent radio (signaling.parameter-request 2 --interval=24) --channel=5
        radio.received.add (fixture.att-event #[0x13, 2, 2, 0, 0, 0] --channel=5)
        radio.received.add #[4, 0x3e, 10, 3, 0, 0x34, 2, 24, 0, 0, 0, 0x90, 1]
        disconnect.get
        radio.received.add #[4, 5, 4, 0, 0x34, 2, 0x13]
        // The second central: the provider opens the controller again.
        radio = provider.radios.receive
        fixture.initialize-replies radio
        accept radio
        radio.received.add (fixture.att-event #[0x0a, STATIC, 0])
        fixture.att-sent radio #[0x0b, 1]
        radio.received.add #[4, 5, 4, 0, 0x34, 2, 0x08]
      finally:
        critical-do --no-respect-deadline: ended.set true
    adapter := ble.Adapter
    try:
      server := ble.GattServer
      service := server.add-service (ble.BleUuid "fff0")
      service.add-characteristic (ble.BleUuid "fff1") --read --value=#[1]
      service.add-characteristic (ble.BleUuid "fff2") --read
          --on-read=:: | connection/ble.Connection | #[0x42]
      written := monitor.Latch
      control := service.add-characteristic (ble.BleUuid "fff3") --write
          --validate=(:: | connection/ble.Connection value/ByteArray |
            if value[0] == 0: throw (ble.AttError ble.AttError.VALUE-NOT-ALLOWED))
          --on-write=(:: | connection/ble.Connection value/ByteArray | written.set value)
      data := service.add-characteristic (ble.BleUuid "fff4") --notify
      peripheral := adapter.peripheral server --advertisement=ADVERTISEMENT
      expect-throw "BLE_SERVER_IN_USE": service.add-characteristic (ble.BleUuid "fff5") --read

      connection := peripheral.accept
      expect-equals ble.ROLE-PERIPHERAL connection.role
      expect-equals (ble.Address #[1, 2, 3, 4, 5, 6] --type=ble.Address.RANDOM) connection.peer
      expect-equals "06:05:04:03:02:01 (random)" connection.peer.stringify
      expect-equals (ble.Phy ble.PHY-1M ble.PHY-1M) connection.phy
      expect-equals 27 connection.data-length.tx-octets
      expect-equals 24 connection.parameters.interval-units
      expect-equals ble.SECURITY-NONE connection.security
      expect-equals [connection] peripheral.connections
      expect-equals #[7] written.get
      expect-equals #[7] control.value
      subscribed.get
      expect-equals 1 (data.notify-values [#[5], #[6]])
      expect-equals #[6] data.value
      expect-equals -60 connection.rssi
      expect-throw "BLE_UNSUPPORTED": connection.discover-services
      applied := connection.request-parameters --interval-min=(Duration --ms=30)
      expect-equals (Duration --ms=30) applied.interval
      expect-equals 24 connection.parameters.interval-units
      expect (not connection.is-closed)
      disconnect.set true
      reason := connection.wait-closed
      expect-equals ble.DisconnectReason.REMOTE-USER reason.code
      expect-equals "remote user terminated (0x13)" reason.stringify
      expect connection.is-closed
      // The last state stays readable until close.
      expect-equals 24 connection.parameters.interval-units
      expect-equals 0 connection.parameters.latency
      connection.close
      expect peripheral.connections.is-empty

      second := peripheral.accept
      expect-equals ble.DisconnectReason.TIMEOUT second.wait-closed.code
      second.close
      peripheral.close
      ended.get
    finally:
      adapter.close
      responder.cancel
      provider.uninstall

/** Scripts the controller side of advertising and a central connecting. */
accept radio/fixture.FakeTransport -> none:
  peripheral-fixture.reply radio 0x2006 (advertising-set.parameters)
  peripheral-fixture.reply radio 0x2008 (advertising-set.data RAW-ADVERTISEMENT)
  peripheral-fixture.reply radio 0x2009 (advertising-set.data #[])
  peripheral-fixture.reply radio 0x200a #[1]
  event := fixture.connection-event.copy
  event[7] = 1
  radio.received.add event
  peripheral-fixture.reply radio 0x200a #[0]
  fixture.att-sent radio (signaling.parameter-request 1) --channel=5
  radio.received.add (fixture.att-event #[0x13, 1, 2, 0, 0, 0] --channel=5)

class Provider extends providers.Provider:
  radios/monitor.Channel ::= monitor.Channel 4

  constructor: super

  open-transport -> transport.Transport:
    radio := fixture.FakeTransport
    radios.send radio
    return radio
