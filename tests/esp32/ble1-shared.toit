// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests the BLE functionality.

Run `ble1-board1.toit` on board1, first.
Once that one is running, run `ble1-board2.toit` on board2.
*/

import ble show *
import expect show *
import monitor

SERVICE-TEST ::= BleUuid "df451d2d-e899-4346-a8fd-bca9cbfebc0b"
SERVICE-TEST2 ::= BleUuid "94a11d6a-fa23-4a09-aa6f-2ca0b7cdbb70"

CHARACTERISTIC-READ-ONLY ::= BleUuid "77d0b04e-bf49-4048-a4cd-fb46be32ebd0"
CHARACTERISTIC-READ-ONLY-CALLBACK ::= BleUuid "9e9f578c-745b-41ec-b0f6-7773157bb5a9"
CHARACTERISTIC-NOTIFY ::= BleUuid "f9f9815f-62a5-49d5-8361-c4c309cee612"
CHARACTERISTIC-INDICATE ::= BleUuid "01dc8c2f-038d-4f75-b836-b6c4245b23ad"
CHARACTERISTIC-WRITE-ONLY ::= BleUuid "1a1bb179-c006-4217-a57b-342e24eca694"
CHARACTERISTIC-WRITE-ONLY-WITH-RESPONSE ::= BleUuid "8e00e1c7-1b90-4f23-8dc9-384134606fc2"

READ-ONLY-VALUE ::= #[0x70, 0x17]

is-peripheral/bool := ?

main-peripheral:
  is-peripheral = true
  adapter := Adapter
  peripheral := adapter.peripheral

  service1 := peripheral.add-service SERVICE-TEST
  service2 := peripheral.add-service SERVICE-TEST2

  read-only := service1.add-read-only-characteristic CHARACTERISTIC-READ-ONLY --value=READ-ONLY-VALUE
  read-only-callback := service1.add-read-only-characteristic CHARACTERISTIC-READ-ONLY-CALLBACK --value=null

  callback-task-done := monitor.Latch
  task::
    counter := 0
    read-only-callback.handle-read-request:
      #[counter++]
    callback-task-done.set null

  notify := service1.add-notification-characteristic CHARACTERISTIC-NOTIFY
  indicate := service2.add-indication-characteristic CHARACTERISTIC-INDICATE
  write-only := service2.add-write-only-characteristic CHARACTERISTIC-WRITE-ONLY
  write-only-with-response := service2.add-write-only-characteristic CHARACTERISTIC-WRITE-ONLY-WITH-RESPONSE

  peripheral.deploy

  advertisement := AdvertisementData
      --name="Test"
      --service-classes=[SERVICE-TEST]
  peripheral.start-advertise --connection-mode=BLE-CONNECT-MODE-UNDIRECTIONAL advertisement

  data := #[]
  while data.size < 5:
    data += write-only.read
  expect-equals #[0, 1, 2, 3, 4] data

  data = #[]
  while data.size < 5:
    data += write-only-with-response.read
  expect-equals #[0, 1, 2, 3, 4] data

  adapter.close
  callback-task-done.get

find-device-with-service central/Central service/BleUuid -> any:
  central.scan --duration=(Duration --s=3): | device/RemoteScannedDevice |
    if device.data.service_classes.contains service:
      print "Found device with service $service: $device"
      return device.address

  throw "No device found with service $service"

main-central --iteration/int:
  is-peripheral = false
  adapter := Adapter
  central := adapter.central

  address := find-device-with-service central SERVICE-TEST
  remote-device := central.connect address

  expect-throw "INVALID_ARGUMENT":
    // The ESP32 does not support discovering multiple services at once.
    remote-device.discover-services [SERVICE-TEST, SERVICE-TEST2]

  if iteration == 0:
    service-list := remote-device.discover-services [SERVICE-TEST]
    expect-equals 1 service-list.size
    service-list = remote-device.discover-services [SERVICE-TEST2]
    expect-equals 1 service-list.size
  else if iteration == 1:
    all-services := remote-device.discover-services
    expect-equals 2 all-services.size

  services := remote-device.discovered-services

  read-only/RemoteCharacteristic? := null
  read-only-callback/RemoteCharacteristic? := null
  notify/RemoteCharacteristic? := null
  indicate/RemoteCharacteristic? := null
  write-only/RemoteCharacteristic? := null
  write-only-with-response/RemoteCharacteristic? := null

  services.do: | service/RemoteService |
    characteristics := service.discover-characteristics
    characteristics.do: | characteristic/RemoteCharacteristic |
      if characteristic.uuid == CHARACTERISTIC-READ-ONLY: read-only = characteristic
      if characteristic.uuid == CHARACTERISTIC-READ-ONLY-CALLBACK: read-only-callback = characteristic
      if characteristic.uuid == CHARACTERISTIC-NOTIFY: notify = characteristic
      if characteristic.uuid == CHARACTERISTIC-INDICATE: indicate = characteristic
      if characteristic.uuid == CHARACTERISTIC-WRITE-ONLY: write-only = characteristic
      if characteristic.uuid == CHARACTERISTIC-WRITE-ONLY-WITH-RESPONSE: write-only-with-response = characteristic

  expect-equals READ-ONLY-VALUE read-only.read

  counter := 0
  5.repeat:
    value := read-only-callback.read
    expect-equals #[counter++] value

  counter = 0
  5.repeat:
    write-only.write #[counter++]

  counter = 0
  5.repeat:
    write-only-with-response.write #[counter++]

  adapter.close

main-central-no-other:
  is-peripheral = false
  adapter := Adapter
  central := adapter.central

  expect-throw "No device found with service $SERVICE-TEST":
     find-device-with-service central SERVICE-TEST

  adapter.close
