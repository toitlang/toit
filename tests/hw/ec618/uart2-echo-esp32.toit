// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio
import uart

/**
ESP32 half of the exhaustive UART2 round-trip test.

Listens on a CONTROL lane (the EC618's UART1 TX, IO4) for the baud rate to use,
  then opens a TEST UART (RX from the EC618's UART2 TX on IO27, TX to the EC618's
  UART2 RX on IO14) at that baud and echoes everything it receives. The EC618 half
  (uart2-echo-ec618.toit) sweeps the baud rates over the control lane and verifies
  the round-trip at each, so one deploy of this program covers the whole sweep
  (unlike the older TX-only uart2-esp32.toit, which needed a per-baud deploy).
  Both directions are 3.3 V now, so driving the EC618 RX directly is safe.

Wiring: EC618 UART1 TX (PAD34) -> IO4 (control RX);
        EC618 UART2 TX (PAD26) -> IO27 (test RX);
        IO14 (test TX) -> EC618 UART2 RX (PAD25).

Run via Jaguar, FIRST (so it is listening before the EC618 sweep starts):

```
  jag run tests/hw/ec618/uart2-echo-esp32.toit --device <esp32>
```
*/

CONTROL-RX ::= 4
TEST-RX ::= 27
TEST-TX ::= 14
CONTROL-BAUD ::= 115200

main:
  control := uart.Port --tx=null --rx=(gpio.Pin CONTROL-RX) --baud-rate=CONTROL-BAUD
  print "uart2-echo-esp32: control RX on IO$CONTROL-RX; ready to echo test UART (IO$TEST-RX in / IO$TEST-TX out)"

  pending/int? := null            // a newly-requested baud (0 = done)
  done := false

  // Control-lane reader: parse newline-delimited baud values from the EC618.
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
          print "uart2-echo-esp32: discarding $buffer.size idle junk bytes"
          buffer = #[]
          continue
      if chunk == null: break
      buffer += chunk
      while true:
        nl := buffer.index-of '\n'
        if nl < 0: break
        line := buffer[..nl].to-string-non-throwing.trim
        buffer = buffer[nl + 1 ..]
        if line != "":
          catch: pending = int.parse line

  test/uart.Port? := null
  rx/gpio.Pin? := null
  tx/gpio.Pin? := null
  while not done:
    if pending != null:
      b := pending
      pending = null
      if test: test.close
      if rx: rx.close
      if tx: tx.close
      test = null
      if b == 0:
        done = true
      else:
        rx = gpio.Pin TEST-RX
        tx = gpio.Pin TEST-TX
        test = uart.Port --rx=rx --tx=tx --baud-rate=b
        print "uart2-echo-esp32: echoing at $b baud"
    if test:
      data/ByteArray? := null
      catch: data = with-timeout --ms=100: test.in.read
      if data: test.out.write data
    else:
      sleep --ms=20

  if test: test.close
  control.close
  print "uart2-echo-esp32: done"
