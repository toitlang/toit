// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor

main:
  test-nested

test-nested:
  latch := monitor.Latch
  expect-throw DEADLINE-EXCEEDED-ERROR:
    with-timeout --ms=100:
      catch:
        with-timeout --ms=1000: latch.get
    unreachable
