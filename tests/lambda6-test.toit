// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

confuse x: return x

create-array x: return Array_ 1: x
create-array x y:
  result := Array_ 2
  result[0] = x
  result[1] = y
  return result

create-list x: return [x]
create-list x y: return [x, y]

expect-array-equals expected given:
  expect given is Array_
  expect-equals expected.size given.size
  for i := 0; i < expected.size; i++:
    expect-equals expected[i] given[i]

create-lambda0: return :: 499

test-0:
  captured-0 := create-lambda0
  expect-equals 499 captured-0.call

create-lambda1 x: return :: x

test-1:
  fun-a := create-lambda1 0
  expect-equals 0 fun-a.call

  fun-b := create-lambda1 [0]
  expect-list-equals [0] fun-b.call

  fun-c := create-lambda1 [1, 2]
  expect-list-equals [1, 2] fun-c.call

  val-d := create-array 0
  fun-d := create-lambda1 val-d
  expect-array-equals val-d fun-d.call

  val-e := create-array 1 2
  fun-e := create-lambda1 val-e
  expect-array-equals val-e fun-e.call

create-lambda2 x y: return :: x + y

test-2:
  x := confuse 400
  y := confuse 99

  fun := create-lambda2 x y
  expect-equals 499 fun.call

main:
  test-0
  test-1
  test-2
