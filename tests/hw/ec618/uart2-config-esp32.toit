// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
ESP32 half of the UART2 configuration-matrix test.

Listens on the CONTROL lane (the EC618's UART1 TX on IO4) for newline lines of
the form "<baud> <data-bits> <parity> <stop-code>" (parity 1=none 2=even 3=odd;
stop-code 1=1 2=1.5 3=2, matching Toit's uart constants), reopens the TEST UART
with that exact configuration, and echoes everything it receives. "Q" quits.

Wiring: EC618 UART1 TX (PAD34) -> IO4 (control RX);
        EC618 UART2 TX (PAD26) -> IO27 (test RX);
        IO14 (test TX) -> EC618 UART2 RX (PAD25).

Run via Jaguar, FIRST (so it is listening before the EC618 starts):

  jag run tests/hw/ec618/uart2-config-esp32.toit --device <esp32>
*/

import gpio
import uart

CONTROL-RX ::= 4
TEST-RX ::= 27
TEST-TX ::= 14
CONTROL-BAUD ::= 115200

stop-bits-of code/int -> uart.StopBits:
  if code == 2: return uart.Port.STOP-BITS-1-5
  if code == 3: return uart.Port.STOP-BITS-2
  return uart.Port.STOP-BITS-1

main:
  control := uart.Port --tx=null --rx=(gpio.Pin CONTROL-RX) --baud-rate=CONTROL-BAUD
  print "uart2-config-esp32: ready (control IO$CONTROL-RX; test IO$TEST-RX in / IO$TEST-TX out)"

  pending/List? := null            // A newly-requested [baud, data, parity, stop].
  done := false

  task::
    buffer := #[]
    while not done:
      chunk := control.in.read
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
        parts := line.split " "
        if parts.size != 4: continue
        config/List? := null
        catch: config = parts.map: int.parse it
        if config: pending = config

  test/uart.Port? := null
  rx/gpio.Pin? := null
  tx/gpio.Pin? := null
  while not done:
    if pending != null:
      config := pending
      pending = null
      if test: test.close
      if rx: rx.close
      if tx: tx.close
      rx = gpio.Pin TEST-RX
      tx = gpio.Pin TEST-TX
      test = uart.Port --rx=rx --tx=tx
          --baud-rate=config[0]
          --data-bits=config[1]
          --parity=config[2]
          --stop-bits=(stop-bits-of config[3])
      print "uart2-config-esp32: test UART $config[0] $(config[1])d p$config[2] s$config[3]"
    if test:
      data/ByteArray? := null
      catch: data = with-timeout --ms=200: test.in.read
      if data: test.out.write data
    else:
      sleep --ms=100

  if test: test.close
  control.close
  print "uart2-config-esp32: done"
