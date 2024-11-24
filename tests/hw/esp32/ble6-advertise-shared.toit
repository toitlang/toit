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

  advertisement := AdvertisementData
      --name="Test"
      --services=[TEST-SERVICE]
  peripheral.start-advertise --allow-connections advertisement
  next-semaphore.down
  peripheral.stop-advertise

  advertisement = AdvertisementData []
  peripheral.start-advertise advertisement
  next-semaphore.down
  peripheral.stop-advertise

  advertise := : | blocks |
    advertisement = AdvertisementData blocks
    peripheral.start-advertise --allow-connections advertisement
    next-semaphore.down
    peripheral.stop-advertise

  advertise.call []
  advertise.call [
    DataBlock.flags --general-discovery --bredr-supported=false,
    DataBlock.manufacturer-specific --company-id=COMPANY-ID MANUFACTURER-DATA,
  ]
  advertise.call [
    DataBlock.name "Test",
    DataBlock.services-128 [TEST-SERVICE],
  ]
  advertise.call [
    DataBlock.manufacturer-specific (ByteArray 27: it)
  ]

  done = true

  peripheral.close
  adapter.close

  print "done"

scan address/ByteArray --central/Central -> RemoteScannedDevice:
  central.scan --duration=(Duration --s=3): | device/RemoteScannedDevice |
    if device.address == address:
      return device
  throw "Device not found"

central-test-counter := 0

test-data
    address/any
    characteristic/RemoteCharacteristic
    --central/Central
    --is-connectable/bool=true [block]:
  remote-scanned := scan address --central=central
  expect-equals address remote-scanned.address
  expect-equals is-connectable remote-scanned.is-connectable
  block.call remote-scanned.data
  characteristic.write #[central-test-counter++]

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

  test-data address characteristic --central=central: | data/AdvertisementData |
    blocks := data.data-blocks
    expect-equals 2 blocks.size
    expect-equals [TEST-SERVICE] data.services
    expect-equals "Test" data.name


  test-data address characteristic --central=central --no-is-connectable: | data/AdvertisementData |
    blocks := data.data-blocks
    expect-equals 0 blocks.size

  test-data address characteristic --central=central: | data/AdvertisementData |
    blocks := data.data-blocks
    expect-equals 0 blocks.size

  test-data address characteristic --central=central: | data/AdvertisementData |
    blocks := data.data-blocks
    expect-equals 2 blocks.size
    expect-equals 0x06 data.flags
    expect-equals COMPANY-ID
        (data.manufacturer-specific: | id data |
          expect-equals MANUFACTURER-DATA data
          id)

  test-data address characteristic --central=central: | data/AdvertisementData |
    blocks := data.data-blocks
    expect-equals 2 blocks.size
    expect-equals "Test" data.name
    expect-equals [TEST-SERVICE] data.services

  test-data address characteristic --central=central: | data/AdvertisementData |
    blocks := data.data-blocks
    expect-equals 1 blocks.size
    expect-equals #[0xff, 0xff]
        (data.manufacturer-specific: | id data |
          expect-equals (ByteArray 27: it) data
          id)

  remote-device.close
  central.close
  adapter.close

  print "done"
