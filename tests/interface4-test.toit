// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

interface A:
  constructor:
    return B

  constructor.named:
    return B

class B implements A:
  x := 0

main:
  expect-equals 0 (A as B).x
  expect-equals 0 (A.named as B).x
