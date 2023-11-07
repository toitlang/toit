// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  test-toplevel
  test-split

test-toplevel:
  expect-equals
    7
    3 + 4
  expect-equals
    7
    // Second:
    3 + 4
  expect-equals
    // First:
    7
    // Second:
    3 + 4
  expect-equals
    // First:
    7

    // Second:
    3 + 4

test-split:
  expect-equals 7
    3 + 4
