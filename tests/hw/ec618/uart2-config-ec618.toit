// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ec618 show Ec618
import uart

/**
EC618 half of the UART2 configuration-matrix test (device under test).

Round-trips a token through the ESP32 echo helper at EVERY combination of
  data bits (5..8), parity (none/even/odd) and stop bits (1/2) at two bauds,
  reopening the EC618 UART2 with the matching configuration each time. A final
  phase deliberately MISMATCHES parity (EC618 even vs ESP32 odd) and checks that
  the driver's error counter reacts; the observed delivery behavior is printed
  either way (we record reality, we don't assume it).

Wiring + helper: see uart2-config-esp32.toit (control = UART1 TX -> IO4).

Run via the mini-jag tester (start uart2-config-esp32.toit on the ESP32 first):

```
  build/host/sdk/bin/toit tests/hw/esp-tester/tester.toit run \
      --chip ec618 --toit-exe build/host/sdk/bin/toit \
      --port-board1 <ec618-uart0-port> tests/hw/ec618/uart2-config-ec618.toit
```
*/

CONTROL-BAUD ::= 115200
BAUDS ::= [115200, 921600]
TOKEN-SIZE ::= 256

stop-bits-of code/int -> uart.StopBits:
  if code == 2: return uart.Port.STOP-BITS-1-5
  if code == 3: return uart.Port.STOP-BITS-2
  return uart.Port.STOP-BITS-1

main:
  control := Ec618.uart1 --baud-rate=CONTROL-BAUD --rx-disabled
  // A fresh UART1 open can emit a glitch byte that garbles the first line on
  // the wire; terminate any such garbage with a newline (the helper discards
  // malformed lines) before the first real command.
  control.out.write "\n"
  sleep --ms=100
  failures := []

  // [data-bits, parity, stop-code]; parity 1=none 2=even 3=odd,
  // stop-code 1=1 3=2 (matrix), plus one 1.5-stop-bit probe (5 data bits is
  // the classic 1.5-stop configuration).
  configs := []
  [5, 6, 7, 8].do: | data/int |
    [1, 2, 3].do: | parity/int |
      [1, 3].do: | stop/int |
        configs.add [data, parity, stop]
  configs.add [5, 1, 2]

  BAUDS.do: | baud/int |
    configs.do: | c/List |
      data := c[0]
      parity := c[1]
      stop := c[2]
      control.out.write "$baud $data $parity $stop\n"
      sleep --ms=700                  // Let the ESP32 reopen its side.
      test := Ec618.uart2
          --baud-rate=baud
          --data-bits=data
          --parity=parity
          --stop-bits=(stop-bits-of stop)
      mask := (1 << data) - 1
      token := ByteArray TOKEN-SIZE: (it * 31 + 7) & mask
      test.out.write token
      got := read-exactly test TOKEN-SIZE
      ok := got == token
      print "uart2-config-ec618: $baud $(data)d p$parity s$stop $(ok ? "ok" : "FAIL (got $got.size bytes$(got.size > 0 and got != token[..got.size] ? ", corrupted" : ""))")"
      if not ok: failures.add "$baud/$(data)d-p$(parity)-s$stop"
      test.close

  // Parity-mismatch phase: the ESP32 echoes with ODD parity while we run
  // EVEN. Every echoed byte arrives with bad parity; the error counter must
  // notice. (What the driver delivers - dropped vs passed-through bytes -
  // is recorded, not asserted.)
  control.out.write "115200 8 3 1\n"
  sleep --ms=700
  test := Ec618.uart2 --baud-rate=115200 --data-bits=8 --parity=uart.Port.PARITY-EVEN
  token := ByteArray TOKEN-SIZE: (it * 31 + 7) & 0xff
  errors-before := test.errors
  test.out.write token
  got := read-exactly test TOKEN-SIZE
  errs := test.errors - errors-before
  print "uart2-config-ec618: parity-mismatch: errors+=$errs delivered=$got.size/$TOKEN-SIZE $(got == token ? "(bytes intact)" : "(bytes dropped/garbled)")"
  if errs == 0: failures.add "parity-mismatch-undetected"
  test.close

  control.out.write "Q\n"
  control.close

  if not failures.is-empty:
    print "uart2-config-ec618: FAIL $failures"
    throw "UART2 config matrix failed: $failures"
  print "uart2-config-ec618: PASS $configs.size configs x $BAUDS.size bauds + parity-error detection"

// Reads exactly n bytes (or fewer on a 3s stall), as one ByteArray.
read-exactly port/uart.Port n/int -> ByteArray:
  result := #[]
  while result.size < n:
    chunk/ByteArray? := null
    catch: chunk = with-timeout --ms=3000: port.in.read
    if chunk == null: break
    result += chunk
  return result.size > n ? result[..n] : result
