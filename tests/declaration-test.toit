// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

foo
    x
:
  return x

class A:
  method
      y
  :
    return y

main:
  // This is a syntax test, so not really testing anything complicated
  // with respect to the dynamic execution.
  expect-equals 499 (foo 499)
  expect-equals 499 ((A).method 499)
