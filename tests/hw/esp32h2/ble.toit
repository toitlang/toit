// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble show *
import expect show *
import system
import uart
import .wiring
import ..esp32.ble-util as util

IS-H2 ::= system.architecture == system.ARCHITECTURE-ESP32H2
SERVICE ::= BleUuid "f8391701-e183-41ed-a513-2ec99f0aa2d7"
READ ::= BleUuid "f8391702-e183-41ed-a513-2ec99f0aa2d7"
WRITE ::= BleUuid "f8391703-e183-41ed-a513-2ec99f0aa2d7"
NOTIFY ::= BleUuid "f8391704-e183-41ed-a513-2ec99f0aa2d7"
VALUE ::= #[1, 3, 5, 7, 9]

main:
  port := uart.Port
      --rx=(IS-H2 ? H2-RX : HELPER-RX)
      --tx=(IS-H2 ? H2-TX : HELPER-TX)
      --baud-rate=115200
  if IS-H2: sleep --ms=1500
  try:
    // Swap roles and reopen the adapter to verify teardown too.
    [true, false].do: | h2-peripheral |
      adapter := Adapter
      try:
        if h2-peripheral == IS-H2:
          peripheral := adapter.peripheral
          service := peripheral.add-service SERVICE
          service.add-read-only-characteristic READ --value=VALUE
          write := service.add-write-only-characteristic WRITE --requires-response
          notify := service.add-notification-characteristic NOTIFY
          peripheral.deploy
          peripheral.start-advertise (Advertisement --name="H2" --services=[SERVICE])
              --connection-mode=BLE-CONNECT-MODE-UNDIRECTIONAL
          port.out.write-byte 1
          expect-equals VALUE write.read
          notify.write VALUE
          expect-equals 2 port.in.read-byte
        else:
          expect-equals 1 port.in.read-byte
          central := adapter.central
          address := util.find-device-with-service central SERVICE
          device := central.connect address
          service := (device.discover-services [SERVICE])[0]
          characteristics := service.discover-characteristics
          read/RemoteCharacteristic? := null
          write/RemoteCharacteristic? := null
          notify/RemoteCharacteristic? := null
          characteristics.do: | characteristic/RemoteCharacteristic |
            if characteristic.uuid == READ: read = characteristic
            if characteristic.uuid == WRITE: write = characteristic
            if characteristic.uuid == NOTIFY: notify = characteristic
          expect-equals VALUE read.read
          notify.subscribe
          write.write VALUE
          expect-equals VALUE notify.wait-for-notification
          device.close
          port.out.write-byte 2
      finally:
        adapter.close
      port.out.write-byte 3
      expect-equals 3 port.in.read-byte
      print "BLE $(h2-peripheral == IS-H2 ? "peripheral" : "central") passed"
  finally:
    port.close
  print "All tests done"
