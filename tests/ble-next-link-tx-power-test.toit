// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// One link's transmit power through the application API: the provider hands
// the link's HCI handle to the transport's vendor control, and a controller
// without that control refuses.

import expect show *
import monitor
import ble.experimental.next as ble
import ble.experimental.transport
import .ble-fixture as fixture
import .ble-next-peripheral-test as peripheral

main:
  with-timeout --ms=10_000:
    [true, false].do: run --control=it

run --control/bool:
  provider := Provider --control=control
  provider.install
  ended := monitor.Latch
  checked := monitor.Latch
  responder := task::
    try:
      radio := provider.radios.receive
      fixture.initialize-replies radio
      peripheral.accept radio
      checked.get
      radio.received.add #[4, 5, 4, 0, 0x34, 2, 0x13]
    finally:
      critical-do --no-respect-deadline: ended.set true
  adapter := ble.Adapter
  try:
    server := ble.GattServer
    role := adapter.peripheral server --advertisement=peripheral.ADVERTISEMENT
    connection := role.accept
    if control:
      expect-equals 6 (connection.set-tx-power 5)
      expect-equals [[0x234, 5]] (provider.radio-controls[0] as PowerRadio).links
      // The link's power comes from the vendor control.
      expect-equals 6 connection.tx-power
    else:
      expect-throw "BLE_UNSUPPORTED": connection.set-tx-power 5
    checked.set true
    connection.wait-closed
    connection.close
    role.close
    ended.get
  finally:
    adapter.close
    responder.cancel
    provider.uninstall

/** A fake controller with vendor power control in 3 dB steps. */
class PowerRadio extends fixture.FakeTransport implements transport.TxPowerControl:
  links/List ::= []
  tx-power -> int?: return 0
  set-tx-power dbm/int -> int?: return closest-tx-power dbm
  closest-tx-power dbm/int -> int: return (dbm + 1) / 3 * 3
  set-connection-tx-power handle/int dbm/int -> int?:
    links.add [handle, dbm]
    return closest-tx-power dbm
  connection-tx-power handle/int -> int?:
    return links.is-empty ? 0 : (closest-tx-power links.last[1])

class Provider extends peripheral.Provider:
  control_/bool
  radio-controls/List ::= []
  constructor --control/bool:
    control_ = control
    super

  open-transport -> transport.Transport:
    if not control_: return super
    radio := PowerRadio
    radio-controls.add radio
    radios.send radio
    return radio
