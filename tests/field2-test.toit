// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

some-fun x:

side-sum := 0
side x: side-sum += x

call-block should-call/bool [block]:
  if should-call: block.call

class A:
  field / any

  constructor .field:

  constructor.x arg:
    if arg:
      field = 1
    else:
      field = 2

  constructor.y arg:
    if arg:
      field = 499
    else:
      throw "arg must be true-ish"

  constructor.z arg:
    if arg:
      throw "arg must be false"
    else:
      field = 42

  constructor.gee:
    for i := 0; i < 1; i++:
      field = 499
      side field
    field = 0

  constructor.foo arg arg2:
    if arg:
      field = 499
      if arg2:
        field++
    else:
      field = -1

  constructor.block should-call:
    call-block should-call:
      field = 498
      field++
      side field
    field = 0

  constructor.logical arg:
    (if true: field = arg else: field = arg) and field++

  constructor.return-local:
    field = 498
    call-block true:
      continue.call-block field++

main:
  expect-equals 42 (A 42).field
  expect-equals 1 (A.x true).field
  expect-equals 2 (A.x false).field
  expect-equals 499 (A.y true).field
  expect-equals 42 (A.z false).field

  expect-equals 0 side-sum
  expect-equals 0 A.gee.field
  expect-equals 499 side-sum

  expect-equals -1 (A.foo false false).field
  expect-equals 499 (A.foo true false).field
  expect-equals 500 (A.foo true true).field

  side-sum = 0
  expect-equals 0 (A.block false).field
  expect-equals 0 side-sum

  side-sum = 0
  expect-equals 0 (A.block true).field
  expect-equals 499 side-sum

  expect-equals 499 (A.logical 498).field

  expect-equals 499 A.return-local.field
