// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests the BLE descriptor functionality.

Run `ble4-board1.toit` on board1, first.
Once that one is running, run `ble4-board2.toit` on board2.
*/

import ble show *
import expect show *
import monitor

TEST-SERVICE ::= BleUuid "df451d2d-e899-4346-a8fd-bca9cbfebc0b"

TEST-CHARACTERISTIC ::= BleUuid "77d0b04e-bf49-4048-a4cd-fb46be32ebd0"
TEST-CHARACTERISTIC-CALLBACK ::= BleUuid "1a1bb179-c006-4217-a57b-342e24eca694"

TEST-DESCRIPTOR ::= BleUuid "a2aef737-c09f-4f8f-bd6c-f80b993300ef"

main-peripheral:
  adapter := Adapter
  peripheral := adapter.peripheral

  service := peripheral.add-service TEST-SERVICE
  characteristic := service.add-characteristic TEST-CHARACTERISTIC
      --properties=CHARACTERISTIC-PROPERTY-READ | CHARACTERISTIC-PROPERTY-WRITE
      --permissions=CHARACTERISTIC-PERMISSION-READ | CHARACTERISTIC-PERMISSION-WRITE
      --value=null
  callback := service.add-write-only-characteristic TEST-CHARACTERISTIC-CALLBACK
  descriptor := characteristic.add-descriptor TEST-DESCRIPTOR
      --properties=CHARACTERISTIC-PROPERTY-READ | CHARACTERISTIC-PROPERTY-WRITE
      --permissions=CHARACTERISTIC-PERMISSION-READ | CHARACTERISTIC-PERMISSION-WRITE
      --value=#['f', 'o', 'o']

  peripheral.deploy

  done-latch := monitor.Latch

  task::
    while true:
      data := callback.read
      if data == #['d', 'o', 'n', 'e']:
        done-latch.set true
        break
      descriptor.set-value data

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

  characteristic-descriptor/RemoteCharacteristic? := null
  characteristic-callback/RemoteCharacteristic? := null

  services.do: | service/RemoteService |
    characteristics := service.discover-characteristics
    characteristics.do: | characteristic/RemoteCharacteristic |
      if characteristic.uuid == TEST-CHARACTERISTIC: characteristic-descriptor = characteristic
      if characteristic.uuid == TEST-CHARACTERISTIC-CALLBACK: characteristic-callback = characteristic

  characteristic-descriptor.discover-descriptors
  discovered-descriptors := characteristic-descriptor.discovered-descriptors
  expect-equals 1 discovered-descriptors.size
  descriptor/RemoteDescriptor := discovered-descriptors.first
  expect-equals TEST-DESCRIPTOR descriptor.uuid

  expect-equals #['f', 'o', 'o'] descriptor.read

  characteristic-callback.write #['b', 'a', 'r']
  value/ByteArray? := null
  // Give the peripheral some time to update the value.
  for i := 0; i < 10; i++:
    value = descriptor.read
    if value == #['b', 'a', 'r']: break
    sleep --ms=10
  expect-equals #['b', 'a', 'r'] value

  characteristic-callback.write #['d', 'o', 'n', 'e']

  print "done"
