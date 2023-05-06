// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor

main:
  test_nested

test_nested:
  latch := monitor.Latch
  expect_throw DEADLINE_EXCEEDED_ERROR:
    with_timeout --ms=100:
      catch:
        with_timeout --ms=1000: latch.get
    unreachable
