// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
import ble
import expect show *
import system
import .ble-server-shared as fixture

main:
  expect-equals system.PLATFORM-ZEPHYR system.platform
  4.repeat: |cycle|
    adapter := ble.Adapter
    central := adapter.central
    2.repeat: |epoch|
      peripheral := adapter.peripheral
      information := peripheral.add-service (ble.BleUuid "180a")
      information.add-read-only-characteristic (ble.BleUuid "2a24") --value="nRF5340"
      wide := peripheral.add-service (ble.BleUuid "12345678")
      wide.add-read-only-characteristic (ble.BleUuid "0000abcd") --value="wide UUID"
      service := peripheral.add-service fixture.SERVICE
      long := service.add-read-only-characteristic fixture.LONG --value=(fixture.payload 512 7)
      long.add-descriptor (ble.BleUuid "2901") --value="nRF5340 server"
      descriptor := long.add-descriptor fixture.DESCRIPTOR
          --properties=ble.CHARACTERISTIC-PROPERTY-READ | ble.CHARACTERISTIC-PROPERTY-WRITE
          --permissions=ble.CHARACTERISTIC-PERMISSION-READ | ble.CHARACTERISTIC-PERMISSION-WRITE
          --value=#[0]
      service.add-read-only-characteristic fixture.EMPTY --value=#[]
      service.add-characteristic fixture.ENCRYPTED
          --properties=ble.CHARACTERISTIC-PROPERTY-READ
          --permissions=ble.CHARACTERISTIC-PERMISSION-READ-ENCRYPTED
          --value="secret"
      notify := service.add-notification-characteristic fixture.NOTIFY
      indicate := service.add-indication-characteristic fixture.INDICATE
      notify.write "initial"
      indicate.write "initial"
      control := service.add-write-only-characteristic fixture.CONTROL --requires-response
      workers := []
      workers.add (add-echo service fixture.REQUEST --response)
      workers.add (add-echo service fixture.COMMAND --no-response)
      workers.add (task --background::
        while true: descriptor.set-value descriptor.read)
      expect-equals "OUT_OF_RANGE" (catch: long.set-value (ByteArray 513))
      // Deferred Toit callbacks must fail explicitly, without blocking RX.
      expect-equals "UNIMPLEMENTED" (catch: long.handle-read-request: "unsupported")
      expect-equals "UNIMPLEMENTED" (catch: control.handle-write-request: null)
      peripheral.deploy
      expect long.handle > 0
      expect descriptor.handle > long.handle
      peripheral.start-advertise (ble.Advertisement --name=(fixture.name cycle epoch)) --allow-connections
      print "NRF5340 BLE SERVER READY cycle=$cycle epoch=$epoch"
      with-timeout --ms=120_000:
        while true:
          command := control.read
          if command == #[0xff]: break
          expect-equals 3 command.size
          target := command[0] == 0 ? notify : indicate
          target.write (fixture.payload command[1] command[2])
      workers.do: it.cancel
      peripheral.close
      // Retiring the local database must not destroy the central manager.
      central.scan --duration=(Duration --ms=0): |device| unreachable
      print "NRF5340 BLE SERVER cycle=$cycle epoch=$epoch PASS"
    adapter.close
  // Exercise process teardown with a registered database and active advertiser.
  adapter := ble.Adapter
  peripheral := adapter.peripheral
  service := peripheral.add-service fixture.SERVICE
  service.add-read-only-characteristic fixture.LONG --value="teardown"
  peripheral.deploy
  peripheral.start-advertise (ble.Advertisement --name="toit-nrf-exit") --allow-connections
  print "NRF5340 BLE SERVER PASS: services, values, queued writes, notify/indicate, reopen and process cleanup"

add-echo service/ble.LocalService uuid/ble.BleUuid --response/bool -> Task:
  property := response ? ble.CHARACTERISTIC-PROPERTY-WRITE : ble.CHARACTERISTIC-PROPERTY-WRITE-WITHOUT-RESPONSE
  characteristic := service.add-characteristic uuid
      --properties=ble.CHARACTERISTIC-PROPERTY-READ | property
      --permissions=ble.CHARACTERISTIC-PERMISSION-READ | ble.CHARACTERISTIC-PERMISSION-WRITE
      --value=#[0]
  return task --background::
    while true: characteristic.set-value characteristic.read
