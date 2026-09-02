// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Verifies that Time.monotonic-us uses the hardware sub-tick counter instead
// of advancing only at the 1 kHz FreeRTOS tick.

main:
  previous := Time.monotonic-us --since-wakeup
  minimum-positive := 1_000_000
  10_000.repeat:
    current := Time.monotonic-us --since-wakeup
    if current < previous:
      print "clock-ec618: FAIL clock moved backwards: $previous -> $current"
      exit 1
    delta := current - previous
    if 0 < delta < minimum-positive: minimum-positive = delta
    previous = current

  if minimum-positive >= 1_000:
    print "clock-ec618: FAIL minimum positive delta is $(minimum-positive)us"
    exit 1

  start := Time.monotonic-us --since-wakeup
  sleep --ms=10
  elapsed := (Time.monotonic-us --since-wakeup) - start
  if not 10_000 <= elapsed < 100_000:
    print "clock-ec618: FAIL 10ms sleep measured $(elapsed)us"
    exit 1

  print "clock-ec618: PASS minimum positive delta $(minimum-positive)us, 10ms sleep $(elapsed)us"
