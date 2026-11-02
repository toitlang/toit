// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio
import uart
import .wiring

main:
  de := gpio.Pin ESP32-UART2-DIRECTION-PIN --input --pull-down
  control := uart.Port --rx=ESP32-UART1-RX-PIN --tx=null --baud-rate=115200
  reply := uart.Port --tx=ESP32-UART2-TX-PIN --rx=null --baud-rate=9600
  failures := []
  cases := []
  print "RS485 LIFECYCLE HELPER READY"
  try:
    buffer := ""
    done := false
    while not done:
      chunk := with-timeout --ms=90_000: control.in.read
      if chunk == null: throw "RS485 control closed"
      buffer += chunk.to-string
      while true:
        nl := buffer.index-of "\n"
        if nl < 0: break
        line := buffer[..nl].trim
        buffer = buffer[nl + 1..]
        if line == "QUIT":
          done = true
          break
        fields := line.split " "
        // Discard the fresh-open glitch/empty line before the first command.
        if fields.size != 3 or fields[0] != "CHECK": continue
        name := fields[1]
        reply.baud-rate = int.parse fields[2]
        level := de.get
        cases.add name
        if level != 0: failures.add name
        print "RS485 LIFECYCLE HELPER $name DE=$level"
        reply.out.write (level == 0 ? #['K'] : #['N']) --flush
  finally:
    reply.close
    control.close
    de.close
  expected := ["empty", "empty-slice", "one-byte", "baud-flush", "baud-writer", "close"]
  if cases.size != expected.size: throw "Unexpected RS485 cases: $cases"
  expected.size.repeat:
    if cases[it] != expected[it]: throw "Unexpected RS485 cases: $cases"
  if not failures.is-empty: throw "RS485 direction stayed high: $failures"
  print "RS485 LIFECYCLE HELPER PASS"
