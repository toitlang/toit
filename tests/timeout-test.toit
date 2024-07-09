// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor

main:
  test-nested
  test-long-sleep

test-nested:
  latch := monitor.Latch
  expect-throw DEADLINE-EXCEEDED-ERROR:
    with-timeout --ms=100:
      catch:
        with-timeout --ms=1000: latch.get
    unreachable

test-long-sleep:
  unit := 30
  10.repeat:
    timeout-ms := unit
    sleep-ms := unit * 2
    unit *= 2
    duration := Duration.of:
      e := catch:
        with-timeout --ms=timeout-ms: sleep --ms=sleep-ms
      expect-equals DEADLINE-EXCEEDED-ERROR e
    duration-ms := duration.in-ms
    if duration-ms >= timeout-ms and duration-ms < sleep-ms:
      // Test succeeded.
      return

  throw "Test failed"
