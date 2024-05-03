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

VALUE-BYTES ::= #[0x70, 0x17]
VALUE-STRING ::= "7017"

main-peripheral --iteration/int:
  print "Iteration $iteration"
  adapter := Adapter
  adapter.set-preferred-mtu 527  // Maximum value.
  peripheral := adapter.peripheral

  service1 := peripheral.add-service SERVICE-TEST
  service2 := peripheral.add-service SERVICE-TEST2

  value := iteration == 0 ? VALUE-BYTES : VALUE-STRING
  read-only := service1.add-read-only-characteristic CHARACTERISTIC-READ-ONLY --value=value
  read-only-callback := service1.add-read-only-characteristic CHARACTERISTIC-READ-ONLY-CALLBACK --value=null

  callback-task-done := monitor.Latch
  // We don't shut down correctly the second time, but we don't want the task
  // stop the program from terminating.
  is-background := (iteration == 1)
  task --background=is-background::
    counter := 0
    read-only-callback.handle-read-request:
      #[counter++]
    callback-task-done.set null

  notify := service1.add-notification-characteristic CHARACTERISTIC-NOTIFY
  indicate := service2.add-indication-characteristic CHARACTERISTIC-INDICATE
  write-only := service2.add-write-only-characteristic CHARACTERISTIC-WRITE-ONLY
  write-only-with-response := service2.add-write-only-characteristic
      --requires-response
      CHARACTERISTIC-WRITE-ONLY-WITH-RESPONSE

  peripheral.deploy

  // Read the handles and make sure they are all different.
  seen-handles := {}
  seen-handles.add-all [read-only.handle, read-only-callback.handle, notify.handle, indicate.handle, write-only.handle, write-only-with-response.handle]
  expect-equals 6 seen-handles.size

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

  // Notifications and indications use different mechanisms for read-requests and subscriptions.
  // The 'write' is sent to all subscribers.
  // The 'handle-read-request' is activated for each read-request.

  task --background=is-background::
    notify.handle-read-request:
      #['F', 'O', 'O']

  task --background=is-background::
    indicate.handle-read-request:
      #['B', 'A', 'R']

  notify.write value
  indicate.write value

  data = write-only.read
  if iteration == 0:
    expect data.size < 500
  else:
    expect-equals 512 data.size

  counter := 0
  while true:  // We use a loop so we can break out of the handle function.
    write-only-with-response.handle-write-request: | chunk/ByteArray |
      expect-equals #[counter++] chunk
      if counter == 5:
        break
    unreachable

  data = write-only.read  // Wait for data from the client
  expect-equals #['n', 'o', 'w'] data

  // At this data was accumulated in the write-only-with-response characteristic.
  // The handle call should get all of the data.
  while true:  // We use a loop so we can break out of the handle function.
    write-only-with-response.handle-write-request: | chunk/ByteArray |
      expect-equals #[0, 1, 2, 3, 4] chunk
      break
    unreachable

  if iteration == 0:
    // In the first iteration close correctly down.
    // In the second one, we let the resource-group do the clean up.
    print "closing things down"
    adapter.close
    callback-task-done.get
  print "end of iteration"

find-device-with-service central/Central service/BleUuid -> any:
  central.scan --duration=(Duration --s=3): | device/RemoteScannedDevice |
    if device.data.service_classes.contains service:
      print "Found device with service $service: $device"
      return device.address

  throw "No device found with service $service"

main-central --iteration/int:
  print "Iteration $iteration"
  adapter := Adapter

  if iteration == 1:
    adapter.set-preferred-mtu 527  // Maximum value.

  central := adapter.central

  address := find-device-with-service central SERVICE-TEST
  remote-device := central.connect address

  if iteration == 0:
    expect remote-device.mtu < 500
  else:
    expect remote-device.mtu == 527

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
    // The device might expose other services. Specifically, 1800 (Generic Access) and 1801 (Generic Attribute).
    expect all-services.size >= 2

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

  // Read the handles and make sure they are all different.
  seen-handles := {}
  seen-handles.add-all [read-only.handle, read-only-callback.handle, notify.handle, indicate.handle, write-only.handle, write-only-with-response.handle]
  expect-equals 6 seen-handles.size

  notify-latch := monitor.Latch
  indicate-latch := monitor.Latch
  notify.subscribe
  indicate.subscribe
  task::
    notify-latch.set notify.wait-for-notification
  task::
    indicate-latch.set indicate.wait-for-notification

  value := iteration == 0 ? VALUE-BYTES : VALUE-STRING.to-byte-array

  expect-equals value read-only.read

  5.repeat:
    expect-equals #[it] read-only-callback.read

  5.repeat:
    write-only.write #[it]

  5.repeat:
    write-only-with-response.write #[it]

  expect-equals value notify-latch.get
  expect-equals value indicate-latch.get

  // We can also read from the notify/indicate characteristics.
  expect-equals #['F', 'O', 'O'] notify.read
  expect-equals #['B', 'A', 'R'] indicate.read

  expect-throw "OUT_OF_RANGE":
    // Check that the MTU is enforced.
    // Remember that the payload is the MTU minus 3.
    write-only.write (ByteArray remote-device.mtu - 2)

  max-packet-size/int := ?
  if iteration == 0:
    max-packet-size = remote-device.mtu - 3
  else:
    max-packet-size = 512
  write-only.write (ByteArray max-packet-size)

  // Give the peripheral time to set up the write-handler.
  sleep --ms=200

  5.repeat:
    write-only-with-response.write #[it]

  // Give the peripheral time to uninitialize the handler.
  sleep --ms=200

  // Write into the characteristic that doesn't have any 'read' or handler.
  5.repeat:
    write-only-with-response.write #[it]
  // Signal that the data was sent.
  write-only.write #['n', 'o', 'w']

  if iteration == 0:
    // In the first iteration close correctly down.
    // In the second one, we let the resource-group do the clean up.
    print "closing things down"
    adapter.close
  print "end of iteration"
