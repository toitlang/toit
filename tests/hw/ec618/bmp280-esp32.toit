// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio
import uart

/**
ESP32 half of the EC618 I2C/BMP280 test: the power switch.

The BMP280 on the breadboard is powered from IO13. This helper switches it
  on command and otherwise stays OFF the I2C nets (IO17/IO18 remain
  unconfigured/high-Z so the EC618 owns the bus). Commands over UART2:

  "P 1" -> sensor power on  (replies "P 1")
  "P 0" -> sensor power off (replies "P 0")
  "Q"   -> power off + quit.

Wiring: EC618 UART2 TX (PAD26) -> IO27; IO14 -> EC618 UART2 RX (PAD25);
        IO13 -> BMP280 VCC; the sensor's SDA/SCL sit on the IO18/IO17 nets
        which also reach the EC618's I2C0 pads (PAD27/PAD28).

Run via Jaguar, FIRST:

```
  jag run tests/hw/ec618/bmp280-esp32.toit --device <esp32>
```
*/

RX ::= 27
TX ::= 14
POWER ::= 13

main:
  port := uart.Port --rx=(gpio.Pin RX) --tx=(gpio.Pin TX) --baud-rate=115200
  power := gpio.Pin POWER --output --value=0
  print "bmp280-esp32: ready (power IO$POWER)"

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
