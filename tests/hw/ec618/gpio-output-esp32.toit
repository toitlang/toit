// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio

import .wiring as wiring
import ..shared.gpio-wait show wait-for-level

/**
ESP32 half of the GPIO-output HW test.

Reads the pin that the EC618 half (gpio-output-ec618.toit) toggles and confirms
  it sees a square wave: it waits for the first edge (the EC618 side starts a
  little after us), then counts edges over a short window.

Prints "gpio-output-esp32: PASS ..." on success. Missing activity or an
  insufficient waveform throws, so a normal container exit cannot hide failure.
*/

// The EC618 side is launched after us (compile + serial install), so wait
// generously for the first edge before giving up.
WAIT-FOR-FIRST ::= Duration --s=40
SAMPLE ::= Duration --s=3
PER-EDGE-TIMEOUT ::= Duration --ms=500
MIN-EDGES ::= 10

main:
  pin := gpio.Pin wiring.ESP32-GPIO11-PIN --input --pull-down
  try:
    print "gpio-output-esp32: waiting up to $(WAIT-FOR-FIRST.in-s)s for activity on IO$(wiring.ESP32-GPIO11-PIN)"
    // An external pull-up can hold the idle wire high. Require a transition
    // from its initial level rather than treating an idle high as activity.
    current := pin.get
    if not (wait-for-level pin (1 - current) WAIT-FOR-FIRST):
      throw "gpio-output-esp32: FAIL no transition within $(WAIT-FOR-FIRST.in-s)s"
    current = 1 - current

    saw-0 := current == 0
    saw-1 := current == 1
    edges := 0
    deadline := Time.monotonic-us + SAMPLE.in-us
    while Time.monotonic-us < deadline:
      next := 1 - current
      if not (wait-for-level pin next PER-EDGE-TIMEOUT): break
      current = next
      if current == 0: saw-0 = true else: saw-1 = true
      edges++

    if edges < MIN-EDGES or not saw-0 or not saw-1:
      throw "gpio-output-esp32: FAIL edges=$edges saw-0=$saw-0 saw-1=$saw-1 (expected >= $MIN-EDGES and both levels)"
    print "gpio-output-esp32: PASS edges=$edges (saw both 0 and 1)"
  finally:
    pin.close
