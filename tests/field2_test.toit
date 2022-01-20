// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

some_fun x:

side_sum := 0
side x: side_sum += x

call_block should_call/bool [block]:
  if should_call: block.call

call_lambda should_call/bool fun/Lambda:
  if should_call: fun.call

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

  constructor.block should_call:
    call_block should_call:
      field = 498
      field++
      side field
    field = 0

  constructor.logical arg:
    (if true: field = arg else: field = arg) and field++

  constructor.return_local:
    field = 497
    call_block true:
      continue.call_block field++
    call_lambda true::
      continue.call_lambda field++

main:
  expect_equals 42 (A 42).field
  expect_equals 1 (A.x true).field
  expect_equals 2 (A.x false).field
  expect_equals 499 (A.y true).field
  expect_equals 42 (A.z false).field

  expect_equals 0 side_sum
  expect_equals 0 A.gee.field
  expect_equals 499 side_sum

  expect_equals -1 (A.foo false false).field
  expect_equals 499 (A.foo true false).field
  expect_equals 500 (A.foo true true).field

  side_sum = 0
  expect_equals 0 (A.block false).field
  expect_equals 0 side_sum

  side_sum = 0
  expect_equals 0 (A.block true).field
  expect_equals 499 side_sum

  expect_equals 499 (A.logical 498).field

  expect_equals 499 A.return_local.field
