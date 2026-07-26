// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio

import .framed-control show FramedChannel
import .uart-rig as rig
import .wiring as wiring

/**
EC618 half of the GPIO-interrupt test (device under test).

The ESP32 drives pulse trains into PAD26 (its IO27); this side counts them with $gpio.Pin.wait-for — the interrupt path, not polling. Checks:

1. 50 pulses at 50 Hz (10 ms per phase) are counted EXACTLY — level interrupts plus the waiter must not miss or double-count edges.
2. A quiet line produces no wakeups (wait-for times out).
3. 50 pulses at 250 Hz (2 ms per phase) — the wait-for loop must turn around faster than a phase; this guards the interrupt dispatch latency.

Commands and acknowledgements use the framed UART1 control channel.
*/

PULSES ::= 50

failures := []

main:
  control-owner := rig.ec618-uart 1 115200
  control := FramedChannel control-owner.port

  // PAD26 is input-only here; the ESP32 drives it push-pull, so no pull.
  pin := gpio.Pin wiring.EC618-GPIO11-PAD --input

  try:
    control.send "HELLO"
    control.expect "READY" --timeout-ms=15_000

    count-pulses control pin 10 "50Hz"

    // Quiet line: no spurious wakeups.
    e := catch: with-timeout --ms=500: pin.wait-for 1
    quiet-ok := e == DEADLINE-EXCEEDED-ERROR
    print "gpio-interrupt-ec618: quiet $(quiet-ok ? "ok" : "FAIL ($e)")"
    if not quiet-ok: failures.add "quiet"

    count-pulses control pin 2 "250Hz"

    control.send "Q"
    control.expect "BYE" --timeout-ms=15_000

    if not failures.is-empty:
      print "gpio-interrupt-ec618: FAIL $failures"
      throw "GPIO interrupt test failed: $failures"
    print "gpio-interrupt-ec618: PASS"
  finally:
    pin.close
    control-owner.close

// Asks the helper for PULSES pulses with the given phase length and counts
// them via wait-for; the count must be exact.
count-pulses control/FramedChannel pin/gpio.Pin phase-ms/int label/string -> none:
  control.send "P $PULSES $phase-ms"
  control.expect "ARMED" --timeout-ms=15_000
  count := 0
  error := catch:
    with-timeout --ms=(2 * PULSES * 2 * phase-ms + 3000):
      PULSES.repeat:
        pin.wait-for 1
        pin.wait-for 0
        count++
  if error != null and error != DEADLINE-EXCEEDED-ERROR: throw error
  control.expect "DONE" --timeout-ms=15_000
  // Allow the line to settle, then make sure no extra edges follow.
  extra := catch: with-timeout --ms=500: pin.wait-for 1
  ok := count == PULSES and extra == DEADLINE-EXCEEDED-ERROR
  print "gpio-interrupt-ec618: $label $(ok ? "ok" : "FAIL") (counted $count/$PULSES$(extra == DEADLINE-EXCEEDED-ERROR ? "" : ", extra edge"))"
  if not ok: failures.add label
