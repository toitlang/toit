// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.cancellation show checkpoint
import expect show *
import monitor

// The rules of docs/ble/design.md, "Cancellation contract", as observed on
// the runtime: checkpoint observes a pending cancellation and an expired
// deadline; catch rethrows CANCELED after its block in a cancelled task;
// waits inside critical-do ignore cancellation.
main:
  checkpoint
  expect-throw DEADLINE-EXCEEDED-ERROR:
    with-timeout --ms=1:
      sleep --ms=5
      checkpoint
  observed := monitor.Latch
  worker := task::
    try:
      sleep --ms=200
    finally:
      critical-do --no-respect-deadline:
        error := catch:
          try:
            checkpoint
          finally: | is-exception exception |
            observed.set (is-exception ? exception.value : null)
        // Inside critical-do the caught cancellation is returned normally.
        expect-equals CANCELED-ERROR error
  sleep --ms=10
  worker.cancel
  expect-equals CANCELED-ERROR observed.get

  // catch in a cancelled task rethrows CANCELED after its block, so code
  // after the catch does not run; a finally does.
  after := monitor.Latch
  worker = task::
    classified := false
    try:
      try:
        sleep --ms=200
      finally: | is-exception exception |
        classified = is-exception
      error := catch: throw "SOME_ERROR"
      after.set "reached after catch with $error"
    finally:
      critical-do --no-respect-deadline: after.set "finally classified=$classified"
  sleep --ms=10
  worker.cancel
  expect-equals "finally classified=true" after.get

  // A latch wait inside critical-do ignores cancellation until it completes.
  latch := monitor.Latch
  done := monitor.Latch
  worker = task::
    try:
      critical-do --no-respect-deadline: latch.get
    finally:
      critical-do --no-respect-deadline: done.set true
  sleep --ms=10
  worker.cancel
  sleep --ms=20
  expect (not done.has-value)
  latch.set true
  with-timeout --ms=500: done.get
