// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import esp32
import expect show *
import gpio
import system.storage
import .control
import .wiring

main:
  bucket := storage.Bucket.open --ram "test/h2-wakeup"
  stage := (bucket.get "stage") or 0
  if stage > 0:
    expect-equals esp32.RESET-DEEPSLEEP esp32.reset-reason
    expect-equals esp32.WAKEUP-EXT1 esp32.wakeup-cause
    expect-equals (1 << H2-WAKE) (esp32.ext1-wakeup-status (1 << H2-WAKE))
    print "External wakeup stage $stage passed"
  control := Control
  if stage < 2:
    initial := stage
    control.command OUTPUT HELPER-WAKE initial
    pin := gpio.Pin H2-WAKE --input
    expect-equals initial pin.get
    bucket["stage"] = stage + 1
    bucket.close
    esp32.enable-external-wakeup (1 << H2-WAKE) (stage == 0)
    control.command DELAYED-OUTPUT HELPER-WAKE (1 - initial)
    // A timer prevents an indefinite sleep; a timer wake is a test failure.
    esp32.deep-sleep (Duration --s=10)
  bucket.remove "stage"
  bucket.close
  control.close
  print "All tests done"
