// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
import ble
import expect show *

main:
  4.repeat: |cycle|
    adapter := ble.Adapter
    central := adapter.central
    peripheral := adapter.peripheral --no-bonding --secure-connections
    service := peripheral.add-service (ble.BleUuid "fff0")
    targets := []
    2.repeat: |index|
      encryption := index == 0
          ? ble.CHARACTERISTIC-PROPERTY-NOTIFY-ENCRYPTION-REQUIRED
          : ble.CHARACTERISTIC-PROPERTY-INDICATE-ENCRYPTION-REQUIRED
      targets.add (service.add-characteristic (ble.BleUuid (index == 0 ? "fff1" : "fff3"))
          --properties=ble.CHARACTERISTIC-PROPERTY-READ | ble.CHARACTERISTIC-PROPERTY-NOTIFY | ble.CHARACTERISTIC-PROPERTY-INDICATE | encryption
          --permissions=ble.CHARACTERISTIC-PERMISSION-READ
          --value="plaintext")
    control := service.add-characteristic (ble.BleUuid "fff2")
        --properties=ble.CHARACTERISTIC-PROPERTY-WRITE | ble.CHARACTERISTIC-PROPERTY-WRITE-WITHOUT-RESPONSE
        --permissions=ble.CHARACTERISTIC-PERMISSION-WRITE
    peripheral.deploy
    peripheral.start-advertise (ble.Advertisement --name="toit-nrf-sec") --allow-connections
    print "NRF5340 BLE NOTIFY SECURITY READY cycle=$cycle"
    with-timeout --ms=60_000:
      // Two sends before encryption, then all four modes after pairing.
      6.repeat: |step|
        command := control.read
        expect-equals 2 command.size
        expect-equals step command[1]
        target := targets[command[0]]
        print "BLE NOTIFY SECURITY sending step=$step"
        target.write command --no-set-value
        print "BLE NOTIFY SECURITY sent step=$step"
      expect-equals "done".to-byte-array control.read
    expect-equals 0 central.bonded-peers.size
    peripheral.close
    adapter.close
    print "BLE NOTIFY SECURITY cycle=$cycle PASS"
  print "NRF5340 BLE NOTIFY SECURITY PASS"
