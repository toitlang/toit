// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

// Independent GATT peer using the existing NimBLE backend on ESP32.
// Each write is echoed as a notification and retained as the readable value.
// The driver sends its next write only after receiving the preceding echo.

import ble show *
import encoding.hex
import system

SERVICE ::= BleUuid "9f6c1000-8e2a-4b13-9e97-94f353eeb001"
INPUT ::= BleUuid "9f6c1001-8e2a-4b13-9e97-94f353eeb001"
ECHO ::= BleUuid "9f6c1002-8e2a-4b13-9e97-94f353eeb001"

main:
  adapter := Adapter
  try:
    adapter.set-preferred-mtu 23
    peripheral := adapter.peripheral
    service := peripheral.add-service SERVICE
    input := service.add-write-only-characteristic INPUT --requires-response
    echo := service.add-characteristic ECHO
        --properties=(CHARACTERISTIC-PROPERTY-READ | CHARACTERISTIC-PROPERTY-NOTIFY)
        --permissions=CHARACTERISTIC-PERMISSION-READ
        --value=#[0x70, 0x17]
    peripheral.deploy
    peripheral.start-advertise --allow-connections
        Advertisement --name="HCI" --services=[SERVICE]
    print "BLE_PEER READY service=$SERVICE platform=$(system.platform)"
    count := 0
    while true:
      value := input.read
      count++
      echo.write value
      print "BLE_PEER ECHO count=$count data=$(hex.encode value)"
  finally:
    adapter.close
