// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

// Dividing int.MIN by -1 used to trap (SIGFPE) and take down the whole VM.
// Ints wrap around, so the quotient is int.MIN and the remainder 0.

main:
  minus-one := -1
  min := int.MIN
  expect-equals int.MIN (min / minus-one)
  expect-equals 0 (min % minus-one)
  expect-equals int.MIN (min / (int.parse "-1"))
  expect-equals 0 (min % (int.parse "-1"))
  expect-equals int.MAX ((min + 1) / minus-one)
  expect-equals 0 ((min + 1) % minus-one)
  expect-equals -4611686018427387904 (min / 2)
  expect-equals 0 (min % 2)
  expect-throw "DIVISION_BY_ZERO": min / 0
  expect-throw "DIVISION_BY_ZERO": min % 0
