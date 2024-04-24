// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests that we can transmit large amounts of data over BLE.

Run `ble2-board1.toit` on board1, first.
Once that one is running, run `ble2-board2.toit` on board2.
*/

import ble show *
import expect show *
import monitor

SERVICE-TEST ::= BleUuid "a1bcf0ba-7557-4968-91f8-6b0f187af2b5"

CHARACTERISTIC-WRITE-ONLY ::= BleUuid "c8aa5ee4-f93e-48cd-b32c-703965a8798f"
CHARACTERISTIC-WRITE-ONLY-WITH-RESPONSE ::= BleUuid "a59d8140-9e81-4a87-aa40-e9c6cab3ed52"

READ-ONLY-VALUE ::= #[0x70, 0x17]

TEST-BYTE-COUNT ::= 500_000

MTU ::= 512
PACKET-SIZE := MTU - 3


main-peripheral:
  adapter := Adapter
  adapter.set-preferred-mtu MTU
  peripheral := adapter.peripheral

  service := peripheral.add-service SERVICE-TEST
  write-only := service.add-write-only-characteristic CHARACTERISTIC-WRITE-ONLY
  write-only-with-response := service.add-write-only-characteristic
      --requires-response
      CHARACTERISTIC-WRITE-ONLY-WITH-RESPONSE

  peripheral.deploy

  advertisement := AdvertisementData
      --name="Test"
      --service-classes=[SERVICE-TEST]
  peripheral.start-advertise --connection-mode=BLE-CONNECT-MODE-UNDIRECTIONAL advertisement

  received := 0
  while received < TEST-BYTE-COUNT:
    data := write-only.read
    received += data.size
    print "Received $received bytes"

  print "all data received"

find-device-with-service central/Central service/BleUuid -> any:
  central.scan --duration=(Duration --s=3): | device/RemoteScannedDevice |
    if device.data.service_classes.contains service:
      print "Found device with service $service: $device"
      return device.address

  throw "No device found with service $service"

main-central:
  adapter := Adapter
  adapter.set-preferred-mtu MTU
  central := adapter.central

  address := find-device-with-service central SERVICE-TEST
  remote-device := central.connect address

  services := remote-device.discover-services

  write-only/RemoteCharacteristic? := null
  write-only-with-response/RemoteCharacteristic? := null

  services.do: | service/RemoteService |
    characteristics := service.discover-characteristics
    characteristics.do: | characteristic/RemoteCharacteristic |
      if characteristic.uuid == CHARACTERISTIC-WRITE-ONLY: write-only = characteristic
      if characteristic.uuid == CHARACTERISTIC-WRITE-ONLY-WITH-RESPONSE: write-only-with-response = characteristic

  data := ByteArray PACKET-SIZE
  total-sent := 0
  List.chunk-up 0 TEST-BYTE-COUNT PACKET-SIZE: | _ _ chunk-size/int |
    while true:
      exception := catch:
        write-only.write data[..chunk-size]
        total-sent += chunk-size
        print "Sent $total-sent bytes"
      if not exception: break
      if exception.contains "error code: 0x06":
        // Need to retry again in a bit.
        sleep --ms=10
      else:
        throw "Unexpected error: $exception"

  // TODO(florian): we currently need to wait for the underlying system to flush the data.
  // Either the `write` or the `close` should do that for us.
  sleep --ms=1_000
  print "all sent"
  adapter.close
