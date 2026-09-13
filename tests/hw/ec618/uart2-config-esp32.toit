// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import uart

import .wiring as wiring

/**
ESP32 half of the UART2 configuration-matrix test.

Listens on the CONTROL lane (the EC618's UART1 TX on IO4) for newline lines of
  the form "<baud> <data-bits> <parity> <stop-code>" (parity 1=none 2=even 3=odd;
  stop-code 1=1 2=1.5 3=2, matching Toit's uart constants), reopens the TEST UART
  with that exact configuration, and echoes everything it receives. "B"
  transmits one byte followed by a 12-bit break; "Q" quits.

*/

CONTROL-BAUD ::= 115200

stop-bits-of code/int -> uart.StopBits:
  if code == 2: return uart.Port.STOP-BITS-1-5
  if code == 3: return uart.Port.STOP-BITS-2
  return uart.Port.STOP-BITS-1

main:
  control := uart.Port --tx=null --rx=wiring.ESP32-UART1-RX-PIN --baud-rate=CONTROL-BAUD
  print "uart2-config-esp32: ready (control IO$(wiring.ESP32-UART1-RX-PIN); test IO$(wiring.ESP32-UART2-RX-PIN) in / IO$(wiring.ESP32-UART2-TX-PIN) out)"

  pending/List? := null            // A newly-requested [baud, data, parity, stop].
  send-break := false
  done := false

  task::
    buffer := #[]
    while not done:
      chunk/ByteArray? := null
      if buffer.is-empty:
        chunk = control.in.read
      else:
        // A partial line that goes idle is reset junk — the EC618 boot ROM
        // sprays a newline-less banner on UART1 at every reset. Discard it
        // so it cannot glue onto the next real command.
        e := catch: chunk = with-timeout --ms=300: control.in.read
        if e:
          print "uart2-config-esp32: discarding $buffer.size idle junk bytes"
          buffer = #[]
          continue
      if chunk == null: break
      buffer += chunk
      while true:
        nl := buffer.index-of '\n'
        if nl < 0: break
        line := buffer[..nl].to-string-non-throwing.trim
        buffer = buffer[nl + 1 ..]
        if line == "": continue
        if line == "Q":
          done = true
          continue
        if line == "B":
          send-break = true
          continue
        parts := line.split " "
        if parts.size != 4: continue
        config/List? := null
        catch: config = parts.map: int.parse it
        if config: pending = config

  test/uart.Port? := null
  while not done:
    if pending != null:
      config := pending
      pending = null
      if test: test.close
      test = uart.Port
          --rx=wiring.ESP32-UART2-RX-PIN
          --tx=wiring.ESP32-UART2-TX-PIN
          --baud-rate=config[0]
          --data-bits=config[1]
          --parity=config[2]
          --stop-bits=(stop-bits-of config[3])
      print "uart2-config-esp32: test UART $config[0] $(config[1])d p$config[2] s$config[3]"
    if send-break and test:
      send-break = false
      // Let the EC618 enter wait-for-break after sending the command.
      sleep --ms=100
      test.out.write #[0x55] --break-length=12 --flush
    if test:
      data/ByteArray? := null
      catch: data = with-timeout --ms=200: test.in.read
      if data: test.out.write data
    else:
      sleep --ms=100

  if test: test.close
  control.close
  print "uart2-config-esp32: done"
