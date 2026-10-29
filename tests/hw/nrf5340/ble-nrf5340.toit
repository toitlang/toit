// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
import ble
import expect show *
import system

main:
  expect-equals system.PLATFORM-ZEPHYR system.platform
  16.repeat: |cycle|
    adapter := ble.Adapter
    expect-equals "ALREADY_IN_USE" (catch: ble.Adapter)
    central := adapter.central
    expect central.bonded-peers.is-empty
    central.scan --duration=(Duration --ms=0): unreachable
    before := Time.monotonic-us
    central.scan --duration=(Duration --ms=30): |device|
      expect-equals 7 device.identifier.size
      expect device.address-type != null
    expect Time.monotonic-us - before >= 30_000
    error := catch:
      with-timeout --ms=30:
        central.scan: |device| null
    expect-equals DEADLINE-EXCEEDED-ERROR error
    // Cancellation must leave the worker and controller reusable.
    central.scan --duration=(Duration --ms=10): |device| null
    central.close
    peripheral := adapter.peripheral --name="Toit nRF5340 test"
    ad := ble.Advertisement --name="toit-nrf-probe"
    response := ble.Advertisement [ble.DataBlock.name "toit-response"]
    peripheral.start-advertise ad --scan-response=response
    expect-equals "ALREADY_EXISTS" (catch: peripheral.start-advertise ad)
    sleep --ms=30
    peripheral.stop-advertise
    peripheral.stop-advertise
    peripheral.start-advertise ad
    // Closing the adapter must stop advertising and close its manager.
    adapter.close
    adapter.close
    print "BLE adapter reopen cycle=$cycle PASS"
  // Leave both operations active for automatic process/VM resource teardown.
  adapter := ble.Adapter
  peripheral := adapter.peripheral
  peripheral.start-advertise (ble.Advertisement --name="toit-final")
  task --background:: adapter.central.scan: |device| null
  sleep --ms=30
  print "NRF5340 BLE TOIT PASS: scan deadlines, cancellation, advertise and 16 adapter reopen cycles"
