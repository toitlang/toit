// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

gee /int := 499

foo x/int:
  return x

foo [x]:
  return x.call

bar -> bool:
  return true

class A:
  bar /int := 499
  operator ~:
    return "not"
  operator / other:
    return "div"

main:
  expect-equals 499 gee

  expect-equals 499 (foo 499)
  expect-equals 499 (foo: 499)

  expect-equals true bar
  expect-equals "not" ~A
  expect-equals "div" A / A

  expect-equals 499 (A).bar
