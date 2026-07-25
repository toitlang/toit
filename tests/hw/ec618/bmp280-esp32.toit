// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio
import uart

import .wiring as wiring

/**
ESP32 half of the EC618 I2C/BMP280 test: the power switch.

The BMP280 on the breadboard is powered from IO13. This helper switches it
  on command and otherwise stays OFF the I2C nets (IO17/IO18 remain
  unconfigured/high-Z so the EC618 owns the bus). Commands over UART2:

  "P 1" -> sensor power on  (replies "P 1")
  "P 0" -> sensor power off (replies "P 0")
  "Q"   -> power off + quit.

*/

main:
  port := uart.Port
      --rx=(gpio.Pin wiring.ESP32-UART2-RX-PIN)
      --tx=(gpio.Pin wiring.ESP32-UART2-TX-PIN)
      --baud-rate=115200
  power := gpio.Pin wiring.ESP32-SENSOR-POWER-PIN --output --value=0
  print "bmp280-esp32: ready (power IO$(wiring.ESP32-SENSOR-POWER-PIN))"

  buffer := #[]
  while true:
    nl := buffer.index-of '\n'
    if nl < 0:
      chunk := port.in.read
      if chunk == null: break
      buffer += chunk
      continue
    line := buffer[..nl].to-string-non-throwing.trim
    buffer = buffer[nl + 1 ..]
    if line == "": continue
    if line == "Q": break
    parts := line.split " "
    if parts.size != 2 or parts[0] != "P": continue
    value := parts[1] == "1" ? 1 : 0
    power.set value
    if value == 1: sleep --ms=20  // Sensor start-up.
    port.out.write "P $value\n"
    print "bmp280-esp32: power $value"

  power.set 0
  power.close
  port.close
  print "bmp280-esp32: done"
