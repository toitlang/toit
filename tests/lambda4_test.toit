// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

glob := (::
  x := 0
  lambda := (:: x++)
).call

class A:
  lambda ::= ?
  field := (::
    x := 0
    (:: x++)
  ).call

  constructor:
    x := 0
    lambda = (:: x++)

  constructor.named:
    x := 0
    lambda = (:: x++)

  constructor .lambda:
  constructor.factory:
    x := 0
    return A (:: x++)

  static static_fun:
    x := 0
    return (:: x++)

  method:
    x := 0
    return (:: x++)

test lambda:
  expect_equals 0 lambda.call
  expect_equals 1 lambda.call
  expect_equals 2 lambda.call

main:
  test glob
  test (A).field
  test (A).lambda
  test (A.named).lambda
  test (A.factory).lambda
  test A.static_fun
  test (A).method
