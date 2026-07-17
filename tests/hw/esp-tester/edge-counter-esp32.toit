// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Generic ESP32 edge counter — the UART-independent execution tracer
(Florian's suggestion): EC618 code under debug toggles a wired pad at
chosen milestones (N crisp pulses = milestone N); this counts edges with
the pulse counter and reports every 2 s, so progress is observable even
when every UART is suspect. Also doubles as a wire-map probe.

Default pin IO4 — the EC618 PAD34 (UART1 TX / GPIO19) wire on the
modest-affair rig; free whenever nothing runs UART1. Edit PIN for other
wires.

EC618-side marker pattern (inline where needed, e.g. system boot code —
gpio primitives work before any service is up, unlike `print`):

  pin := gpio.Pin 34 --output   // Pin numbers are PAD numbers.
  N.repeat: pin.set 1; sleep --ms=2; pin.set 0; sleep --ms=2
  pin.close
*/

import gpio
import pulse-counter

PIN ::= 4
REPORT-MS ::= 2_000
TOTAL-MS ::= 240_000

main:
  pin := gpio.Pin PIN --input
  unit := pulse-counter.Unit pin --glitch-filter-ns=1_000
  print "edge-counter: counting rising edges on IO$PIN for $(TOTAL-MS / 1000)s"
  last := 0
  (TOTAL-MS / REPORT-MS).repeat:
    sleep --ms=REPORT-MS
    v := unit.value
    if v != last:
      print "edge-counter: total=$v (+$(v - last))"
      last = v
  print "edge-counter: done total=$last"
