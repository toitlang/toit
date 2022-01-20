// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

class A:
  operator [] [b]:
    return b.call

  stored := 0
  operator []= [b] [b2]:
    stored = b.call + b2.call

main:
  expect_equals 499 A[:499]
  a := A
  a[:400] = :99
  expect_equals 499 a.stored
