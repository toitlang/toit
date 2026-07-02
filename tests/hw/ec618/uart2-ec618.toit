// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
EC618 half of the UART2 HW test (device under test).

Sends a known, self-describing token line ("EC618-UART2 <baud> <n>") repeatedly
on UART2 TX at the baud rate given as the test argument, so the ESP32 half
(uart2-esp32.toit, reading RX-only on IO27 at the same baud) can confirm it
receives cleanly-framed data at that baud. The harness runs this pair once per
baud to sweep the supported range (an "exhaustive" baud check rather than a
single does-it-work check).

Wiring: EC618 GPIO11 / PAD26 (UART2 TX, mapping 0) -> ESP32 IO27 (the same wire
the gpio-output test already connectivity-verified). UART2 is opened TX-only
(--rx-disabled), so only the EC618 drives the line and the ESP32 RX is high-
impedance — no contention, no short risk on the direct wiring.

Run via the mini-jag tester, passing the baud as --arg (start the ESP32 half
first, at the same baud, so it is already listening):

  build/host/sdk/bin/toit tests/hw/esp-tester/tester.toit run \
      --chip ec618 --toit-exe build/host/sdk/bin/toit --arg 115200 \
      --port-board1 <ec618-uart0-port> tests/hw/ec618/uart2-ec618.toit

(--port-board1 is the EC618's UART0 port — the CH340 adapter; the /dev/ttyUSBN
number swaps between sessions, so identify it by chip. See docs/ec618-hw-tests.md.)
*/

import ec618 show Ec618
import uart

TOKEN ::= "EC618-UART2"
DEFAULT-BAUD ::= 115200
DURATION ::= Duration --s=12   // Long enough for the ESP32 to catch many lines.
GAP ::= Duration --ms=20

main args:
  baud := args.is-empty ? DEFAULT-BAUD : int.parse args[0]
  // TX-only: only GPIO11/PAD26 is claimed and driven; the RX pad stays free.
  port := Ec618.uart2 --baud-rate=baud --rx-disabled
  print "uart2-ec618: sending \"$TOKEN $baud <n>\" on UART2 TX (GPIO11) at $baud baud for $(DURATION.in-s)s"
  deadline := Time.monotonic-us + DURATION.in-us
  n := 0
  while Time.monotonic-us < deadline:
    port.out.write "$TOKEN $baud $n\n"
    port.out.flush
    n++
    sleep GAP
  port.close
  print "uart2-ec618: done ($n lines at $baud baud)"
