// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ec618 show Ec618
import gpio
import uart

/**
EC618 half of the GPIO-interrupt test (device under test).

The ESP32 drives pulse trains into PAD26 (its IO27); this side counts them
  with $gpio.Pin.wait-for — the interrupt path, not polling. Checks:

1. 50 pulses at 50 Hz (10 ms per phase) are counted EXACTLY — level
   interrupts plus the waiter must not miss or double-count edges.
2. A quiet line produces no wakeups (wait-for times out).
3. 50 pulses at 250 Hz (2 ms per phase) — the wait-for loop must turn
   around faster than a phase; this guards the interrupt dispatch latency.

Commands go over UART1 TX -> ESP32 IO4 (one-directional; all assertions
  run here, the helper just drives).

Wiring: EC618 UART1 TX (PAD34) -> IO4 (control);
        IO27 -> EC618 PAD26 (the pulse line; ESP32 3.3 V push-pull).

Run via the mini-jag tester (start gpio-interrupt-esp32.toit FIRST):

```
  build/host/sdk/bin/toit tests/hw/esp-tester/tester.toit run \
      --chip ec618 --toit-exe build/host/sdk/bin/toit \
      --port-board1 <ec618-uart0-port> tests/hw/ec618/gpio-interrupt-ec618.toit
```
*/

PULSES ::= 50

failures := []

main:
  control := Ec618.uart1 --baud-rate=115200 --rx-disabled
  // Terminate the possible open-glitch byte (see uart2-config-ec618.toit).
  control.out.write "\n"
  sleep --ms=100

  // PAD26 is input-only here; the ESP32 drives it push-pull, so no pull.
  // (PAD26 is pull-up-only anyway; see gpio-pull.)
  pin := gpio.Pin 26 --input

  count-pulses control pin 10 "50Hz"

  // Quiet line: no spurious wakeups.
  e := catch: with-timeout --ms=500: pin.wait-for 1
  quiet-ok := e == DEADLINE-EXCEEDED-ERROR
  print "gpio-interrupt-ec618: quiet $(quiet-ok ? "ok" : "FAIL ($e)")"
  if not quiet-ok: failures.add "quiet"

  count-pulses control pin 2 "250Hz"

  control.out.write "Q\n"
  control.close
  pin.close

  if not failures.is-empty:
    print "gpio-interrupt-ec618: FAIL $failures"
    throw "GPIO interrupt test failed: $failures"
  print "gpio-interrupt-ec618: PASS"

// Asks the helper for PULSES pulses with the given phase length and counts
// them via wait-for; the count must be exact.
count-pulses control/uart.Port pin/gpio.Pin phase-ms/int label/string -> none:
  control.out.write "P $PULSES $phase-ms\n"
  count := 0
  catch:  // On timeout report the partial count instead of dying.
    with-timeout --ms=(2 * PULSES * 2 * phase-ms + 3000):
      PULSES.repeat:
        pin.wait-for 1
        pin.wait-for 0
        count++
  // Allow the line to settle, then make sure no extra edges follow.
  extra := catch: with-timeout --ms=500: pin.wait-for 1
  ok := count == PULSES and extra == DEADLINE-EXCEEDED-ERROR
  print "gpio-interrupt-ec618: $label $(ok ? "ok" : "FAIL") (counted $count/$PULSES$(extra == DEADLINE-EXCEEDED-ERROR ? "" : ", extra edge"))"
  if not ok: failures.add label
