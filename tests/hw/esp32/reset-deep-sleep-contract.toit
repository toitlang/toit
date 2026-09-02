// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Verifies the ESP32 reset and minimum-duration deep-sleep contracts.

The test is self-verifying across the two reboots it requests. Install it as a
  boot-triggered container. A flash-backed state byte distinguishes the three
  stages and is cleared after the final result, making the test re-runnable.
*/

import esp32
import system.storage

BUCKET-NAME ::= "test/esp32-reset-deep-sleep-contract"
STATE-KEY ::= "state"

main:
  assert-equals (Duration --ms=50) esp32.DEEP-SLEEP-MIN-DURATION

  bucket := storage.Bucket.open --flash BUCKET-NAME
  state := ((bucket.get STATE-KEY) or #[0])[0]

  if state == 0:
    bucket[STATE-KEY] = #[1]
    bucket.close
    print "reset/deep-sleep contract: requesting explicit reset"
    esp32.reset

  if state == 1:
    assert-equals esp32.RESET-SOFTWARE esp32.reset-reason
    assert-equals esp32.WAKEUP-UNDEFINED esp32.wakeup-cause
    bucket[STATE-KEY] = #[2]
    bucket.close
    print "reset/deep-sleep contract: requesting zero-duration deep sleep"
    esp32.deep-sleep Duration.ZERO

  if state == 2:
    // A zero-duration request is clamped to the hardware minimum and remains
    // a real timer-backed deep sleep. It must not look like a software reset.
    assert-equals esp32.RESET-DEEPSLEEP esp32.reset-reason
    assert-equals esp32.WAKEUP-TIMER esp32.wakeup-cause
    bucket[STATE-KEY] = #[0]
    bucket.close
    print "ESP32 RESET/DEEP-SLEEP CONTRACT PASSED"
    return

  bucket[STATE-KEY] = #[0]
  bucket.close
  throw "invalid reset/deep-sleep contract state: $state"

assert-equals expected actual:
  if expected != actual: throw "expected $expected, got $actual"
