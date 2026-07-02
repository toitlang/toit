// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
ESP32 half of the EC618 I2C clock-stretch test: power switch + SCL squatter.

Extends the bmp280-esp32 power helper with a stretch command: the ESP32
plays the stretching slave by holding the SCL net low, OPEN-DRAIN ONLY
(drive low / release to high-Z — never push high, so there is no
contention with the master; this is electrically exactly what a real
clock-stretching slave does).

Commands over UART2:
  "P 1" / "P 0"      -> sensor power on/off (replies "P <v>")
  "H <delay> <hold>" -> reply "H ok" immediately, then after <delay> ms
                        hold SCL low for <hold> ms and release.
  "Q"                -> power off + quit.

Wiring: EC618 UART2 TX (PAD26) -> IO27; IO14 -> EC618 UART2 RX (PAD25);
        IO13 -> BMP280 VCC; SCL net = EC618 PAD24 <-> IO22 (the stretch
        target); SDA net = PAD23 <-> IO33 (untouched here).

Run via Jaguar, FIRST:

  jag run tests/hw/ec618/i2c-stretch-esp32.toit --device <esp32>
*/

import gpio
import uart

RX ::= 27
TX ::= 14
POWER ::= 13
SCL ::= 22

main:
  port := uart.Port --rx=(gpio.Pin RX) --tx=(gpio.Pin TX) --baud-rate=115200
  power := gpio.Pin POWER --output --value=0
  // Open-drain, idle released: value 1 = high-Z (the bus pull-up rules),
  // value 0 = actively held low. Never drives high.
  scl := gpio.Pin SCL --output --open-drain --value=1
  print "i2c-stretch-esp32: ready (power IO$POWER, SCL squat IO$SCL open-drain)"

  buffer := #[]
  while true:
    nl := buffer.index-of '\n'
    if nl < 0:
      chunk/ByteArray? := null
      if buffer.is-empty:
        chunk = port.in.read
      else:
        // Reset-junk discard (boot-ROM banner) — see uart2-bigdata-esp32.
        e := catch: chunk = with-timeout --ms=300: port.in.read
        if e:
          print "i2c-stretch-esp32: discarding $buffer.size idle junk bytes"
          buffer = #[]
          continue
      if chunk == null: break
      buffer += chunk
      continue
    line := buffer[..nl].to-string-non-throwing.trim
    buffer = buffer[nl + 1 ..]
    if line == "": continue
    if line == "Q": break
    parts := line.split " "
    if parts[0] == "P" and parts.size == 2:
      value := parts[1] == "1" ? 1 : 0
      power.set value
      if value == 1: sleep --ms=20  // Sensor start-up.
      port.out.write "P $value\n"
      print "i2c-stretch-esp32: power $value"
    else if parts[0] == "H" and parts.size == 3:
      delay := int.parse parts[1] --if-error=: continue
      hold := int.parse parts[2] --if-error=: continue
      port.out.write "H ok\n"
      task::
        sleep --ms=delay
        scl.set 0
        print "i2c-stretch-esp32: SCL held low ($hold ms)"
        sleep --ms=hold
        scl.set 1
        print "i2c-stretch-esp32: SCL released"

  power.set 0
  power.close
  scl.set 1
  scl.close
  port.close
  print "i2c-stretch-esp32: done"
