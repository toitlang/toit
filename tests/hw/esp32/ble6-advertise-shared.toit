// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests that we can advertise and read different fields.

Also tests the scan response.

Run `ble6-advertise-board1.toit` on board1, first.
Once that one is running, run `ble6-advertise-board2.toit` on board2.
*/

import ble show *
import expect show *
import monitor

import .ble-util

TEST-SERVICE ::= BleUuid "eede145e-b6a6-4d61-8156-ed10d5b75903"
TEST-CHARACTERISTIC ::= BleUuid "6b50d82f-ae33-4e0e-b161-50db92c49ad2"

COMPANY-ID ::= #[0x12, 0x34]
MANUFACTURER-DATA ::= #[0x56, 0x78]

main-peripheral:
  adapter := Adapter
  peripheral := adapter.peripheral

  service := peripheral.add-service TEST-SERVICE
  characteristic := service.add-characteristic TEST-CHARACTERISTIC
      --properties=CHARACTERISTIC-PROPERTY-READ | CHARACTERISTIC-PROPERTY-WRITE
      --permissions=CHARACTERISTIC-PERMISSION-READ | CHARACTERISTIC-PERMISSION-WRITE
      --value=null

  peripheral.deploy

  next-semaphore := monitor.Semaphore
  done := false

  task::
    count := 0
    while not done:
      characteristic.handle-write-request: | data/ByteArray |
        if data.is-empty: throw "Unexpected empty data"
        if data[0] == count:
          print "."
          count++
          next-semaphore.up
        else:
          throw "Unexpected data: $data"

  advertisement := Advertisement
      --name="Test"
      --services=[TEST-SERVICE]
  peripheral.start-advertise --allow-connections advertisement
  next-semaphore.down
  peripheral.stop-advertise

  advertisement = Advertisement []
  peripheral.start-advertise advertisement
  next-semaphore.down
  peripheral.stop-advertise

  advertise := : | blocks scan-response-blocks |
    advertisement = Advertisement blocks
    scan-response := scan-response-blocks
        ? Advertisement scan-response-blocks
        : null
    peripheral.start-advertise
        advertisement
        --allow-connections
        --scan-response=scan-response

    next-semaphore.down
    peripheral.stop-advertise

  advertise.call [] null
  advertise.call [
      DataBlock.flags --general-discovery --bredr-supported=false,
      DataBlock.manufacturer-specific --company-id=COMPANY-ID MANUFACTURER-DATA,
    ]
    null
  advertise.call [
      DataBlock.name "Test",
      DataBlock.services-128 [TEST-SERVICE],
    ]
    null
  advertise.call [
      DataBlock.manufacturer-specific (ByteArray 27: it)
    ]
    null
  advertise.call
    [
      DataBlock.name "Test",
    ]
    [  // The scan response.
      DataBlock.services-128 [TEST-SERVICE],
    ]
  advertise.call [
      DataBlock.flags --general-discovery,
      DataBlock.name "Test",
    ]
    null

  done = true

  peripheral.close
  adapter.close

  print "done"

scan identifier/ByteArray --central/Central -> RemoteScannedDevice:
  central.scan --duration=(Duration --s=3): | device/RemoteScannedDevice |
    if device.identifier == identifier:
      return device
  throw "Device not found"

central-test-counter := 0

test-data
    identifier/any
    characteristic/RemoteCharacteristic
    --central/Central
    --is-connectable/bool=true
    [block]:
  remote-scanned := scan identifier --central=central
  expect remote-scanned.address-bytes is ByteArray
  expect-equals 6 (remote-scanned.address-bytes as ByteArray).size
  expect-equals RemoteScannedDevice.ADDRESS-TYPE-PUBLIC remote-scanned.address-type
  expect-not remote-scanned.is-scan-response
  expect-equals identifier remote-scanned.identifier
  expect-equals is-connectable remote-scanned.is-connectable
  block.call remote-scanned.data
  characteristic.write #[central-test-counter++]

main-central:
  adapter := Adapter
  central := adapter.central

  identifier := find-device-with-service central TEST-SERVICE

  remote-device := central.connect identifier
  all-services := remote-device.discover-services
  services := remote-device.discovered-services

  characteristic/RemoteCharacteristic? := null

  services.do: | service/RemoteService |
    characteristics := service.discover-characteristics
    characteristics.do: | found/RemoteCharacteristic |
      if found.uuid == TEST-CHARACTERISTIC: characteristic = found

  test-data identifier characteristic --central=central: | data/Advertisement |
    blocks := data.data-blocks
    expect-equals 2 blocks.size
    expect-equals [TEST-SERVICE] data.services
    expect-equals "Test" data.name

  test-data identifier characteristic --central=central --no-is-connectable: | data/Advertisement |
    blocks := data.data-blocks
    expect-equals 0 blocks.size

  test-data identifier characteristic --central=central: | data/Advertisement |
    blocks := data.data-blocks
    expect-equals 0 blocks.size

  test-data identifier characteristic --central=central: | data/Advertisement |
    blocks := data.data-blocks
    expect-equals 2 blocks.size
    expect-equals 0x06 data.flags
    expect-equals COMPANY-ID
        (data.manufacturer-specific: | id data |
          expect-equals MANUFACTURER-DATA data
          id)

  test-data identifier characteristic --central=central: | data/Advertisement |
    blocks := data.data-blocks
    expect-equals 2 blocks.size
    expect-equals "Test" data.name
    expect-equals [TEST-SERVICE] data.services

  test-data identifier characteristic --central=central: | data/Advertisement |
    blocks := data.data-blocks
    expect-equals 1 blocks.size
    expect-equals #[0xff, 0xff]
        (data.manufacturer-specific: | id data |
          expect-equals (ByteArray 27: it) data
          id)

  // Check that active/passive scanning works.
  central.scan --duration=(Duration --s=2): | device/RemoteScannedDevice |
    if device.identifier == identifier:
      // Without doing an active scan we don't get a scan response.
      expect-not device.is-scan-response

  advertisement/Advertisement? := null
  scan-response/Advertisement? := null
  while true:  // Use a loop to be able to break out of the block.
    central.scan --duration=(Duration --s=3) --active: | device/RemoteScannedDevice |
      if device.identifier == identifier:
        if device.is-scan-response:
          scan-response = device.data
        else:
          advertisement = device.data
        if advertisement and scan-response: break
    break

  expect-equals 1 advertisement.data-blocks.size
  expect-equals "Test" advertisement.name
  expect-equals 1 scan-response.data-blocks.size
  expect-equals [TEST-SERVICE] scan-response.services

  characteristic.write #[central-test-counter++]

  // Test limited scanning.
  central.scan --duration=(Duration --s=1) --limited-only: | device/RemoteScannedDevice |
    if device.identifier == identifier: unreachable
  // But we should find the device with general scanning.
  while true:  // Use a loop to be able to break out of the block.
    central.scan --duration=(Duration --s=3): | device/RemoteScannedDevice |
      if device.identifier == identifier: break
    unreachable

  characteristic.write #[central-test-counter++]

  remote-device.close
  central.close
  adapter.close

  print "done"
