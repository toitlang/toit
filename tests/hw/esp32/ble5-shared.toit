// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests write responses, empty values, and fragmented reads at ATT MTU 23.

Run `ble5-board1.toit` on board1, first.
Once that one is running, run `ble5-board2.toit` on board2.
*/

import ble show *
import expect show *
import monitor

import .ble-util
import .test
import .variants

TEST-SERVICE ::= BleUuid Variant.CURRENT.ble5-service
TEST-CHARACTERISTIC ::= BleUuid "77d0b04e-bf49-4048-a4cd-fb46be32ebd0"
LONG-CHARACTERISTIC ::= BleUuid "717b4940-d72f-4b35-8aad-2af778d68e12"
EMPTY-CHARACTERISTIC ::= BleUuid "717b4941-d72f-4b35-8aad-2af778d68e12"

long-value -> ByteArray:
  return ByteArray 512: (it * 73 + 19) & 0xff

main-peripheral:
  run-test: test-peripheral

test-peripheral:
  adapter := Adapter
  adapter.set-preferred-mtu 23
  peripheral := adapter.peripheral

  service := peripheral.add-service TEST-SERVICE
  characteristic := service.add-characteristic TEST-CHARACTERISTIC
      --properties=CHARACTERISTIC-PROPERTY-READ | CHARACTERISTIC-PROPERTY-WRITE
      --permissions=CHARACTERISTIC-PERMISSION-READ | CHARACTERISTIC-PERMISSION-WRITE
      --value=null

  service.add-read-only-characteristic LONG-CHARACTERISTIC --value=long-value
  service.add-read-only-characteristic EMPTY-CHARACTERISTIC --value=#[]

  peripheral.deploy

  done-latch := monitor.Latch

  task::
    while true:
      characteristic.handle-write-request: | data/ByteArray |
        if data == #['d', 'o', 'n', 'e']:
          done-latch.set true
          break
        characteristic.set-value data

  advertisement := Advertisement
      --name="Test"
      --services=[TEST-SERVICE]
  peripheral.start-advertise --connection-mode=BLE-CONNECT-MODE-UNDIRECTIONAL advertisement

  done-latch.get

main-central:
  run-test: test-central

test-central:
  adapter := Adapter
  adapter.set-preferred-mtu 23
  central := adapter.central
  address := find-device-with-service central TEST-SERVICE
  remote-device := central.connect address
  all-services := remote-device.discover-services
  services := remote-device.discovered-services

  characteristic/RemoteCharacteristic? := null
  long/RemoteCharacteristic? := null
  empty/RemoteCharacteristic? := null

  services.do: | service/RemoteService |
    characteristics := service.discover-characteristics
    characteristics.do: | found/RemoteCharacteristic |
      if found.uuid == TEST-CHARACTERISTIC: characteristic = found
      if found.uuid == LONG-CHARACTERISTIC: long = found
      if found.uuid == EMPTY-CHARACTERISTIC: empty = found

  10.repeat: | iteration/int |
    print "."
    expect-equals 23 characteristic.mtu
    // A 512-byte read takes 24 ATT responses at this MTU. Check the full
    // payload repeatedly to catch dropped fragments and mbuf exhaustion.
    expect-equals long-value (with-timeout --ms=5000: long.read)
    expect-equals #[] (with-timeout --ms=1000: empty.read)
    ["", "foo-$iteration", "bar-$iteration", "gee-$iteration"].do: | value |
      with-timeout --ms=1000: characteristic.write value
      expect-equals value.to-byte-array (with-timeout --ms=1000: characteristic.read)

  characteristic.write "done"
