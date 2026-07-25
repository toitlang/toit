// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio

import .wiring as wiring

/**
ESP32 half of the GPIO-output HW test.

Reads the pin that the EC618 half (gpio-output-ec618.toit) toggles and confirms
  it sees a square wave: it waits for the first edge (the EC618 side starts a
  little after us), then counts edges over a short window.

Prints a single "gpio-output-esp32: PASS ..." / "... FAIL ..." verdict line.
*/

// The EC618 side is launched after us (compile + serial install), so wait
// generously for the first edge before giving up.
WAIT-FOR-FIRST ::= Duration --s=40
SAMPLE ::= Duration --s=3
PER-EDGE-TIMEOUT ::= Duration --ms=500
MIN-EDGES ::= 10

main:
  pin := gpio.Pin wiring.ESP32-GPIO11-PIN --input --pull-down
  print "gpio-output-esp32: waiting up to $(WAIT-FOR-FIRST.in-s)s for activity on IO$(wiring.ESP32-GPIO11-PIN)"

  saw-activity := (catch: with-timeout WAIT-FOR-FIRST: pin.wait-for 1) == null
  if not saw-activity:
    print "gpio-output-esp32: FAIL no high level seen on IO$(wiring.ESP32-GPIO11-PIN) within $(WAIT-FOR-FIRST.in-s)s (EC618 not driving or started late — settle and retry; if it persists, power-cycle the ESP32: a latched input reads frozen while the wire is fine)"
    pin.close
    return

  // Count edges over the sample window.
  current := pin.get
  saw-0 := current == 0
  saw-1 := current == 1
  edges := 0
  deadline := Time.monotonic-us + SAMPLE.in-us
  while Time.monotonic-us < deadline:
    next := 1 - current
    timed-out := (catch: with-timeout PER-EDGE-TIMEOUT: pin.wait-for next) != null
    if timed-out: break
    current = next
    if current == 0: saw-0 = true else: saw-1 = true
    edges++
  pin.close

  if edges >= MIN-EDGES and saw-0 and saw-1:
    print "gpio-output-esp32: PASS edges=$edges (saw both 0 and 1)"
  else:
    print "gpio-output-esp32: FAIL edges=$edges saw-0=$saw-0 saw-1=$saw-1 (expected >= $MIN-EDGES; both levels + few edges usually means the EC618 session started late and we sampled the wave's tail — settle and retry)"
