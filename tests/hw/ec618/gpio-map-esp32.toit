// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
ESP32 half of the rig connectivity-map test.

Holds a broad set of candidate input pins low (input + pull-down, so nothing is
driven), waits for the EC618's sync burst on IO27 to lock t0, then for each fixed
time slot reports which input pin(s) toggled — i.e. which ESP32 pin is wired to
the EC618 GPIO bit driven in that slot (see gpio-map-ec618.toit for the schedule).
EC618 drives -> ESP32 reads only, so there is no short-circuit risk.

Run via Jaguar (output to the serial console), BEFORE the EC618 half:

  jag run tests/hw/ec618/gpio-map-esp32.toit --device <esp32>
*/

import gpio

ANCHOR ::= 27
// Candidate ESP32 input pins wired to the EC618 (GPIO-capable, with internal
// pulls; excludes the analog DAC pins IO25/26 and input-only/flash pins).
WATCH ::= [27, 21, 14, 16, 4, 13, 33, 32, 23, 22, 19, 18, 17, 2]
// Slot order — MUST match BITS in gpio-map-ec618.toit. (GPIO11 is not a slot; it
// is the sync anchor on IO27.)
EC618-BITS ::= [10, 16, 17, 18, 19]

// Schedule constants — MUST match gpio-map-ec618.toit.
SYNC-MS ::= 6 * 2 * 80
LEAD-IN-MS ::= 600
SLOT-MS ::= 3000
WAIT-FOR-SYNC ::= Duration --s=40

main:
  pins := {:}
  WATCH.do: | n/int | pins[n] = gpio.Pin n --input --pull-down
  print "gpio-map-esp32: waiting up to $(WAIT-FOR-SYNC.in-s)s for the sync burst on IO$ANCHOR"
  if (catch: with-timeout WAIT-FOR-SYNC: pins[ANCHOR].wait-for 1) != null:
    print "gpio-map-esp32: FAIL no sync seen on IO$ANCHOR (EC618 not driving, or wire missing)"
    pins.do: | n pin | pin.close
    return
  t0 := Time.monotonic-us
  print "gpio-map-esp32: sync detected; mapping $(EC618-BITS.size) slots"

  EC618-BITS.size.repeat: | i/int |
    slot-start-ms := SYNC-MS + LEAD-IN-MS + i * SLOT-MS
    // Sample the middle 60% of the slot to avoid boundary edges.
    sample-start-us := t0 + (slot-start-ms + SLOT-MS / 5) * 1000
    sample-end-us := t0 + (slot-start-ms + SLOT-MS * 4 / 5) * 1000
    now := Time.monotonic-us
    if now < sample-start-us: sleep --ms=((sample-start-us - now) / 1000)
    counts := {:}
    WATCH.do: | n/int | counts[n] = 0
    samples := 0
    while Time.monotonic-us < sample-end-us:
      WATCH.do: | n/int | if pins[n].get == 1: counts[n] = counts[n] + 1
      samples++
      sleep --ms=3
    toggled := WATCH.filter: | n/int | counts[n] > 0 and counts[n] < samples
    stuck-high := WATCH.filter: | n/int | samples > 0 and counts[n] == samples
    line := "gpio-map-esp32: EC618 GPIO$(EC618-BITS[i]) <-> ESP32 IO$toggled"
    if not stuck-high.is-empty: line += "  (always-high: IO$stuck-high)"
    print line

  pins.do: | n pin | pin.close
  print "gpio-map-esp32: done"
