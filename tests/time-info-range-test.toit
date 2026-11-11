// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

// The time-info primitive must not return the uninitialized fields of a
// failed conversion (timestamps whose year doesn't fit an int).

time-info timestamp/int is-utc/bool -> List:
  #primitive.core.time-info

main:
  [true, false].do: | is-utc |
    info := time-info 0 is-utc
    expect-equals 9 info.size
    [int.MAX, int.MIN, 1 << 60, -(1 << 60)].do: | timestamp |
      expect-throw "OUT_OF_RANGE": time-info timestamp is-utc
  utc := time-info 0 true
  expect-equals 1970 utc[5]
  expect-equals 0 utc[4]
  expect-equals 1 utc[3]
