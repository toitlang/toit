// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
ESP32 half of the UART2 HW test.

Opens a UART RX-only on IO27 (where the EC618's UART2 TX is wired) at the baud
given as the program argument, and confirms it receives several cleanly-framed
lines carrying that exact baud value ("EC618-UART2 <baud> <n>"). Counting
newline-delimited lines that contain the exact expected prefix verifies framing
AND content at that baud — at a wrong baud the bytes would be garbage and never
match. RX-only (no TX pin), so the ESP32 drives nothing on the shared wire.

Wiring: EC618 GPIO11 / PAD26 (UART2 TX) -> ESP32 IO27.

Run via Jaguar (start this FIRST so it is already listening, then launch
uart2-ec618.toit via the tester). NOTE: `jag run` cannot pass program arguments
to a networked device, so the baud here defaults to 115200; an automated
multi-baud sweep needs the in-device control lane (the EC618 telling the ESP32
the baud over UART1) — see docs/ec618-hw-tests.md.

  jag run tests/hw/ec618/uart2-esp32.toit --device <esp32>

Reads the ESP32 serial console (e.g. via the CP2102N port) for the single
"uart2-esp32: PASS ..." / "... FAIL ..." verdict line.
*/

import gpio
import uart

RX-PIN ::= 27
DEFAULT-BAUD ::= 115200
TOKEN ::= "EC618-UART2"
MIN-LINES ::= 5
// The EC618 side is launched after us (compile + serial install), so wait
// generously before giving up.
WAIT ::= Duration --s=40

main args:
  baud := args.is-empty ? DEFAULT-BAUD : int.parse args[0]
  expect := "$TOKEN $baud "
  rx := gpio.Pin RX-PIN
  port := uart.Port --tx=null --rx=rx --baud-rate=baud
  print "uart2-esp32: RX-only on IO$RX-PIN at $baud baud, want >= $MIN-LINES lines \"$expect<n>\" (up to $(WAIT.in-s)s)"

  good := 0
  buffer := #[]
  err := catch:
    with-timeout WAIT:
      while good < MIN-LINES:
        chunk := port.in.read
        if chunk == null: throw "uart closed"
        buffer += chunk
        while true:
          nl := buffer.index-of '\n'
          if nl < 0: break
          line := buffer[..nl].to-string-non-throwing
          buffer = buffer[nl + 1 ..]
          if line.contains expect: good++
        // Bound the buffer; keep a tail in case a line spans the boundary.
        if buffer.size > 4096: buffer = buffer[buffer.size - 256 ..]

  port.close
  rx.close

  if good >= MIN-LINES:
    print "uart2-esp32: PASS baud=$baud received $good cleanly-framed lines"
  else:
    print "uart2-esp32: FAIL baud=$baud only $good/$MIN-LINES clean lines (err=$err)"
