// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio
import uart

import .wiring as wiring

/**
ESP32 half of the GPIO open-drain test: the second bus master.

Holds IO16 (the shared wire) and acts on commands:

  "B"     -> (re)configure IO16 as input with pull-up; reply "B <level>".
  "R"     -> read the wire; reply "R <level>".
  "O <v>" -> reconfigure IO16 as a REAL open-drain output (pull-up kept)
             driving v; reply "O".
  "C"     -> back to input + pull-up; reply "C".
  "Q"     -> quit.

All assertions run on the EC618 (gpio-opendrain-ec618.toit).

*/

main:
  port := uart.Port
      --rx=(gpio.Pin wiring.ESP32-UART2-RX-PIN)
      --tx=(gpio.Pin wiring.ESP32-UART2-TX-PIN)
      --baud-rate=115200
  bus := gpio.Pin wiring.ESP32-OPEN-DRAIN-BUS-PIN --input --pull-up
  print "gpio-opendrain-esp32: ready (bus IO$(wiring.ESP32-OPEN-DRAIN-BUS-PIN))"

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
    command := parts[0]
    if command == "B":
      bus.configure --input --pull-up
      port.out.write "B $bus.get\n"
    else if command == "R":
      port.out.write "R $bus.get\n"
    else if command == "O" and parts.size == 2:
      value := int.parse parts[1]
      bus.configure --input --output --open-drain --pull-up --value=value
      port.out.write "O\n"
    else if command == "C":
      bus.configure --input --pull-up
      port.out.write "C\n"
    else if command == "P" and parts.size == 2:
      if parts[1] == "d":
        bus.configure --input --pull-down
      else:
        bus.configure --input --pull-up
      port.out.write "P\n"
    print "gpio-opendrain-esp32: $line -> bus $bus.get"

  bus.close
  port.close
  print "gpio-opendrain-esp32: done"
