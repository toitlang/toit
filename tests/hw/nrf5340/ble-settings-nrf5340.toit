// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
import ble
import expect show *

main:
  // Seed "Toit nRF5340 test" with ble-nrf5340.toit before flashing this
  // program with ble-settings-native.c. Never set the GAP name here: the
  // native observer checks the value restored by the adapter worker.
  16.repeat: |cycle|
    adapter := ble.Adapter
    sleep --ms=50
    expect adapter.central.bonded-peers.is-empty
    adapter.central.scan --duration=(Duration --ms=20): |device| null
    peripheral := adapter.peripheral
    peripheral.start-advertise (ble.Advertisement --name="toit-settings")
    sleep --ms=20
    adapter.close
    print "BLE settings reopen cycle=$cycle PASS"
  print "NRF5340 BLE SETTINGS PASS"
