// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

confuse x: return x

create_array x: return Array_ 1: x
create_array x y:
  result := Array_ 2
  result[0] = x
  result[1] = y
  return result

create_list x: return [x]
create_list x y: return [x, y]

expect_array_equals expected given:
  expect given is Array_
  expect_equals expected.size given.size
  for i := 0; i < expected.size; i++:
    expect_equals expected[i] given[i]

create_lambda0: return :: 499

test_0:
  captured_0 := create_lambda0
  expect_equals 499 captured_0.call

create_lambda1 x: return :: x

test_1:
  fun_a := create_lambda1 0
  expect_equals 0 fun_a.call

  fun_b := create_lambda1 [0]
  expect_list_equals [0] fun_b.call

  fun_c := create_lambda1 [1, 2]
  expect_list_equals [1, 2] fun_c.call

  val_d := create_array 0
  fun_d := create_lambda1 val_d
  expect_array_equals val_d fun_d.call

  val_e := create_array 1 2
  fun_e := create_lambda1 val_e
  expect_array_equals val_e fun_e.call

create_lambda2 x y: return :: x + y

test_2:
  x := confuse 400
  y := confuse 99

  fun := create_lambda2 x y
  expect_equals 499 fun.call

main:
  test_0
  test_1
  test_2
