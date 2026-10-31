// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
import ble
import expect show *

main:
  run --bonding --secure-connections

run --bonding/bool --secure-connections/bool --reject-pairing/bool=false:
  4.repeat: |cycle|
    adapter := ble.Adapter
    central := adapter.central
    print "BLE SERVER SECURITY initial bonds=$(central.bonded-peers.size) cycle=$cycle"
    peripheral := adapter.peripheral --bonding=bonding --secure-connections=secure-connections
    service := peripheral.add-service (ble.BleUuid "fff0")
    encrypted := service.add-characteristic (ble.BleUuid "fff1")
        --properties=ble.CHARACTERISTIC-PROPERTY-READ | ble.CHARACTERISTIC-PROPERTY-WRITE
        --permissions=ble.CHARACTERISTIC-PERMISSION-READ-ENCRYPTED | ble.CHARACTERISTIC-PERMISSION-WRITE-ENCRYPTED
        --value="nrf-secure-v1"
    descriptor := encrypted.add-descriptor (ble.BleUuid "fff3")
        --properties=ble.CHARACTERISTIC-PROPERTY-READ | ble.CHARACTERISTIC-PROPERTY-WRITE
        --permissions=ble.CHARACTERISTIC-PERMISSION-READ-ENCRYPTED | ble.CHARACTERISTIC-PERMISSION-WRITE-ENCRYPTED
        --value="desc-initial"
    control := service.add-write-only-characteristic (ble.BleUuid "fff2")
    peripheral.deploy
    peripheral.start-advertise (ble.Advertisement --name="toit-nrf-sec") --allow-connections
    print "NRF5340 BLE SERVER SECURITY READY cycle=$cycle"
    with-timeout --ms=45_000:
      if not reject-pairing:
        expect-equals "from-esp-sec".to-byte-array encrypted.read
        encrypted.write "ack-sec"
        expect-equals "from-desc-sec".to-byte-array descriptor.read
        descriptor.set-value "ack-desc"
      expect-equals "done".to-byte-array control.read
    if reject-pairing:
      expect-equals DEADLINE-EXCEEDED-ERROR
          catch: with-timeout --ms=50: encrypted.read
    expect-equals (bonding ? 1 : 0) central.bonded-peers.size
    peripheral.close
    adapter.close
    print "BLE SERVER SECURITY cycle=$cycle PASS"
  print "NRF5340 BLE SERVER SECURITY PASS"
