// Copyright (C) 2025 Toit contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests that the total run-time is plausibly correct.
*/

import esp32
import expect show *
import system.storage

import .test

RUNTIME-KEY ::= "runtime-before-sleep"

main:
  run-test: test

test:
  current-run-time-us := esp32.total-run-time
  print "Current time: $current-run-time-us"
  bucket := storage.Bucket.open --ram "toitlang.org/runtime-test"
  runtime-before-sleep := bucket.get RUNTIME-KEY
  if runtime-before-sleep:
    expect current-run-time-us > runtime-before-sleep
    diff := current-run-time-us - runtime-before-sleep
    expect diff < 1_000_000  // 1s.
  else:
    // We can't expect the current time to have a certain value, as the mini-jag
    // (testing harness) might have delayed running the test.
    // However, as of 2025-06-03 mini-jag has a check that the total-run-time is
    // in a reasonable range.
    new-total := esp32.total-run-time
    expect new-total > current-run-time-us
    bucket[RUNTIME-KEY] = new-total
    bucket.close
    // By going into deep sleep we don't return to the `run-test` function
    // which would print the ALL-TESTS-DONE message.
    esp32.deep-sleep Duration.ZERO
