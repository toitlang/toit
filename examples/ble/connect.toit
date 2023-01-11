// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble

BATTERY_SERVICE ::= ble.BleUuid "180F"
BATTERY_LEVEL   ::= ble.BleUuid "2A19"

SCAN_DURATION   ::= Duration --s=3

find_with_service central/ble.Central service/ble.BleUuid:
  central.scan --duration=SCAN_DURATION: | device/ble.RemoteScannedDevice |
    if device.data.service_classes.contains service:
        return device.address
  throw "no device found"

main:
  adapter := ble.Adapter
  central := adapter.central

  address := find_with_service central BATTERY_SERVICE
  remote_device := central.connect address
  // Discover the battery service.
  services := remote_device.discover_services [BATTERY_SERVICE]
  battery_service/ble.RemoteService := services.first

  // Discover the battery level characteristic.
  characteristics := battery_service.discover_characteristics [BATTERY_LEVEL]
  battery_level_characteristic/ble.RemoteCharacteristic := characteristics.first

  // Read the battery level which is a value between 0 and 100.
  value := battery_level_characteristic.read
  battery_level := value[0]

  print "Battery level of $address: $battery_level%"
