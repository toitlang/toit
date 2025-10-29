// Copyright (C) 2025 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests that there can be multiple services with the same UUID.
Similarly, test, that there can be multiple characteristics with the same UUID.

Run `ble7-duplicate-board1.toit` on board1, first.
Once that one is running, run `ble7-duplicate-board2.toit` on board2.
*/

import ble show *
import expect show *
import monitor

import .ble-util
import .test
import .variants

TEST-SERVICE ::= BleUuid Variant.CURRENT.ble7-service
TEST-CHARACTERISTIC ::= BleUuid "788e77dc-28df-43d1-b40e-eca5c4f551a3"
TEST-DESCRIPTOR ::= BleUuid "505f69ff-f90c-49d2-af8c-84cd47fdb8ff"

DONE-CHARACTERISTIC ::= BleUuid "f975accd-c715-46e6-9458-1cac128dacb5"

main-peripheral:
  run-test: test-peripheral

test-peripheral:
  adapter := Adapter
  peripheral := adapter.peripheral

  service := peripheral.add-service TEST-SERVICE
  characteristic1_1 := service.add-read-only-characteristic
      TEST-CHARACTERISTIC
      --value=#[11]
  characteristic1_1.add-descriptor TEST-DESCRIPTOR --value=#[1, 1]
  characteristic1_2 := service.add-read-only-characteristic
      TEST-CHARACTERISTIC
      --value=#[12]
  characteristic1_2.add-descriptor TEST-DESCRIPTOR --value=#[1, 2]

  service2 := peripheral.add-service TEST-SERVICE
  characteristic2_1 := service2.add-read-only-characteristic
      TEST-CHARACTERISTIC
      --value=#[21]
  characteristic2_1.add-descriptor TEST-DESCRIPTOR --value=#[2, 1]
  characteristic2_2 := service2.add-read-only-characteristic
      TEST-CHARACTERISTIC
      --value=#[22]
  characteristic2_2.add-descriptor TEST-DESCRIPTOR --value=#[2, 2]

  done := service.add-write-only-characteristic DONE-CHARACTERISTIC

  peripheral.deploy

  advertisement := Advertisement
      --name="Test"
      --services=[TEST-SERVICE]

  peripheral.start-advertise --connection-mode=BLE-CONNECT-MODE-UNDIRECTIONAL advertisement

  done.read

  peripheral.close
  adapter.close

  print "done"

scan identifier/ByteArray --central/Central -> RemoteScannedDevice:
  central.scan --duration=(Duration --s=3): | device/RemoteScannedDevice |
    if device.identifier == identifier:
      return device
  throw "Device not found"

main-central:
  run-test: test-central

test-central:
  adapter := Adapter
  central := adapter.central

  identifier := find-device-with-service central TEST-SERVICE

  remote-device := central.connect identifier
  all-services := remote-device.discover-services
  test-services := []
  all-services.do: | service/RemoteService |
    if service.uuid == TEST-SERVICE:
      test-services.add service

  expect-equals 2 test-services.size

  done/RemoteCharacteristic? := null
  characteristics-values := {:}
  test-services.do: | service/RemoteService |
    characteristics := service.discover-characteristics
    characteristics.do: | characteristic/RemoteCharacteristic |
      if characteristic.uuid == DONE-CHARACTERISTIC:
        done = characteristic
      if characteristic.uuid == TEST-CHARACTERISTIC:
        value := characteristic.read
        descriptors := characteristic.discover-descriptors
        descriptors.do: | descriptor/RemoteDescriptor |
          if descriptor.uuid == TEST-DESCRIPTOR:
            characteristics-values[value] = descriptor.read

  expect-equals 4 characteristics-values.size
  keys := characteristics-values.keys.map: it[0]
  expect-equals [11, 12, 21, 22] keys.sort
  expect-equals #[1, 1] characteristics-values[#[11]]
  values := characteristics-values.values
  [
    #[1, 1],
    #[1, 2],
    #[2, 1],
    #[2, 2],
  ].do: | expected/ByteArray |
    expect (values.contains expected)

  done.write #[100]

  remote-device.close
  central.close
  adapter.close
