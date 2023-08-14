// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

count := 0

side x:
  count++
  return x

check-side-count expected-side-calls [b]:
  before := count
  b.call
  expect-equals expected-side-calls (count - before)

run [b]:
  return b.call

main:
  x := 1 < 2 < 3 < 4
  expect-equals true x

  x =
    if 3 > 2 < 4: true else: false
  expect-equals true x

  check-side-count 4:
    expect-equals true ((side 1) < (side 2) < (side 3) < (side 4))

  check-side-count 1:
    x = run: 1 < (side 2) > 3 ? "no!" : "ok"
  expect-equals "ok" x

  check-side-count 1:
    x = run: 1 <= (side 2) >= 3 ? "no!" : "ok"
  expect-equals "ok" x

  b := true
  expect-equals true (b == 1 < 2)
  expect-equals false (b == 2 < 1)
  expect-equals true (1 < 2 == b)
  expect-equals false (2 < 1 == b)
  expect-equals false (b != 1 < 2)
  expect-equals true (b != 2 < 1)
  expect-equals false (1 < 2 != b)
  expect-equals true (2 < 1 != b)
