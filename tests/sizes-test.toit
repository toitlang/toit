// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import .confuse

class A:
  size -> int:
    return 499

  size x:
    return x

main:
  expect-equals 0 (confuse []).size
  expect-equals 3 (confuse [1, 2, 3]).size
  expect-equals 3 (confuse #[1, 2, 3]).size
  expect-equals 5 (confuse (ByteArray 5)).size
  expect-equals 4 (confuse (ByteArray 10)[1..5]).size
  array := Array_ 499
  expect-equals 499 (confuse array).size
  big-array := Array_ 100000
  expect-equals 100000 (confuse big-array).size
  expect-equals 5 ((confuse A).size 5)
  expect-equals 499 (confuse A).size
