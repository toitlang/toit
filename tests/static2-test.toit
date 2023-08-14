// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

class A:
  static foo x:
    return x

  static bar := 33

main:
  expect-equals 499 (A.foo 499)
  expect-equals 33 A.bar
  A.bar++
  expect-equals 34 A.bar
  A.bar += 2
  expect-equals 36 A.bar
