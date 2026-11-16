// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import monitor

// Returns false only for a deadline. Driver errors must not be interpreted
// as a quiet wire. The pin is duck-typed to allow fault injection on the host.
wait-for-level pin/any level/int timeout/Duration -> bool:
  error := catch --unwind=(: it != DEADLINE-EXCEEDED-ERROR):
    with-timeout timeout: pin.wait-for level
  return error == null

// Runs the wait independently while forwarding its result or original
// exception to the caller. A failed worker must not leave the observer
// waiting forever, nor turn its failure into a clean capture.
capture-level pin/any level/int timeout/Duration -> monitor.Latch:
  result := monitor.Latch
  task::
    catch:
      try:
        result.set (wait-for-level pin level timeout)
      finally: |is-exception exception|
        if is-exception:
          critical-do --no-respect-deadline:
            result.set --exception exception
  return result
