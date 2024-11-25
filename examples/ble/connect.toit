// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble

BATTERY-SERVICE ::= ble.BleUuid "180F"
BATTERY-LEVEL   ::= ble.BleUuid "2A19"

SCAN-DURATION   ::= Duration --s=3

find-with-service central/ble.Central service/ble.BleUuid:
  central.scan --duration=SCAN-DURATION: | device/ble.RemoteScannedDevice |
    if device.data.contains-service service:
        return device.address
  throw "no device found"

main:
  adapter := ble.Adapter
  central := adapter.central

  address := find-with-service central BATTERY-SERVICE
  remote-device := central.connect address
  // Discover the battery service.
  services := remote-device.discover-services [BATTERY-SERVICE]
  battery-service/ble.RemoteService := services.first

  // Discover the battery level characteristic.
  characteristics := battery-service.discover-characteristics [BATTERY-LEVEL]
  battery-level-characteristic/ble.RemoteCharacteristic := characteristics.first

  // Read the battery level which is a value between 0 and 100.
  value := battery-level-characteristic.read
  battery-level := value[0]

  print "Battery level of $address: $battery-level%"
