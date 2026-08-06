// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import .test

main:
  run-test: test

test:
  // Warm up the reusable native timer so its one-time allocation is not part
  // of the latency measurement.
  sleep --ms=1

  minimum-us := 1 << 60
  25.repeat:
    before := Time.monotonic-us
    sleep --ms=2
    elapsed-us := Time.monotonic-us - before
    expect elapsed-us >= 2_000
    minimum-us = min minimum-us elapsed-us

  // The 100Hz FreeRTOS tick used to make every short asynchronous sleep take
  // at least one 10ms tick. Allow ample scheduling jitter, but require at least
  // one sample that clearly did not wait for such a tick.
  expect minimum-us < 6_000
