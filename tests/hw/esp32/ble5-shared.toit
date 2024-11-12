// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests that we can set a value of a descriptor when handling a request.

Run `ble5-board1.toit` on board1, first.
Once that one is running, run `ble5-board2.toit` on board2.
*/

import ble show *
import expect show *
import monitor

TEST-SERVICE ::= BleUuid "df451d2d-e899-4346-a8fd-bca9cbfebc0b"
TEST-CHARACTERISTIC ::= BleUuid "77d0b04e-bf49-4048-a4cd-fb46be32ebd0"

main-peripheral:
  adapter := Adapter
  peripheral := adapter.peripheral

  service := peripheral.add-service TEST-SERVICE
  characteristic := service.add-characteristic TEST-CHARACTERISTIC
      --properties=CHARACTERISTIC-PROPERTY-READ | CHARACTERISTIC-PROPERTY-WRITE
      --permissions=CHARACTERISTIC-PERMISSION-READ | CHARACTERISTIC-PERMISSION-WRITE
      --value=null

  peripheral.deploy

  done-latch := monitor.Latch

  task::
    while true:
      characteristic.handle-write-request: | data/ByteArray |
        if data == #['d', 'o', 'n', 'e']:
          done-latch.set true
          break
        characteristic.set-value data

  advertisement := AdvertisementData
      --name="Test"
      --service-classes=[TEST-SERVICE]
  peripheral.start-advertise --connection-mode=BLE-CONNECT-MODE-UNDIRECTIONAL advertisement

  done-latch.get
  print "done"


find-device-with-service central/Central service/BleUuid -> any:
  central.scan --duration=(Duration --s=3): | device/RemoteScannedDevice |
    if device.data.service_classes.contains service:
      print "Found device with service $service: $device"
      return device.address

  throw "No device found with service $service"

main-central:
  adapter := Adapter
  central := adapter.central
  address := find-device-with-service central TEST-SERVICE
  remote-device := central.connect address
  all-services := remote-device.discover-services
  services := remote-device.discovered-services

  characteristic/RemoteCharacteristic? := null

  services.do: | service/RemoteService |
    characteristics := service.discover-characteristics
    characteristics.do: | found/RemoteCharacteristic |
      if found.uuid == TEST-CHARACTERISTIC: characteristic = found

  10.repeat: | iteration/int |
    print "."
    ["foo-$iteration", "bar-$iteration", "gee-$iteration"].do: | value |
      characteristic.write value
      expect-equals value.to-byte-array characteristic.read

  characteristic.write "done"

  print "done"
