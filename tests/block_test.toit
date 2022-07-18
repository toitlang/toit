// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  test_nested_block_params
  test_random_in_block
  test_non_local_return
  test_update_local_from_block
  test_update_parameter_from_block null
  test_nested_blocks 1
  test_nested_blocks 2
  expect test_return_from_nested_blocks == 42
  test_passing_too_many_args
  test_multiple_blocks
  test_block_in_blocks

  sum := 0
  [ 2, 3, 5, 7 ].do: sum += it
  expect sum == 2 + 3 + 5 + 7

  // Test that we can access outer locals where the
  // number of arguments passed to the various blocks and
  // the associated exec lambdas differ.
  i := 42
  j := exec:
    exec2: | x y | i
  expect_equals 42 j

  expect_equals 42 (extract:: 42).call
  expect_equals 87 (extract:: 87).call
  expect_equals sum (extract:: sum).call
  expect_equals
    7 + 3 + 4 - (1 + 2)
    (funky 7).call
  expect_equals 4
    (extract:: it + 1).call 3
  expect_equals 3
    (extract:: | a b | a - b).call 7 4

funky n:
  x := 1 + 2
  y := 3 + 4
  return extract:: n + y - x

test_random_in_block:
  result := exec:
    random
  print result

test_non_local_return:
  tree := Tree random null null
  for i := 0; i <= 25; i++: tree.add random
  tree.do: print it

  expect_equals 7 add_3_4
  expect_equals 5 add_3_r5
  expect_equals 8 (add_3_p 5)
  expect_equals 6 (add_3_rp 6)
  expect_equals 7 add_3_l4
  expect_equals 5 add_3_rl5

test_update_local_from_block:
  n := 0
  exec: n = 42
  expect_equals 42 n
  exec: n = 87
  expect_equals 87 n

test_update_parameter_from_block n:
  exec: n = 42
  expect_equals 42 n
  exec: n = 87
  expect_equals 87 n

test_nested_blocks x:
  org := x
  y := 4
  exec:
    z := x + y
    exec:
      y = z + x
      x = 4
  expect_equals 4 x
  expect_equals (org + 4 + org) y

test_nested_block_params:
  execx 7: | n | expect_equals 7 n
  execx 8: | n | expect_equals 8 n
  execx 9: | n | exec: expect_equals 9 n
  execx 10: | n |
    n = 11
    expect_equals 11 n
  execx 11:
    | n |
    exec: n = 12
    expect_equals 12 n

test_return_from_nested_blocks:
  exec:
    exec:
      return 42
  unreachable


invoke_lambda f:
  return f.call

invoke_lambda x f:
  return f.call x

invoke_lambda x y f:
  return f.call x y

invoke_block [b]:
  return b.call

invoke_block x [b]:
  return b.call x

invoke_block x y [b]:
  return b.call x y

test_passing_too_many_args:
  x := false
  execx 5: x = true
  expect x

  exec2: x = it
  expect_equals 100 x

  expect_equals 499 (invoke_lambda 0:: 499)
  expect_equals 499 (invoke_block 0: 499)
  expect_equals 42 (invoke_lambda 42 2:: it)
  expect_equals 42 (invoke_block 42 2: it)

test_multiple_blocks:
  x := 0
  expect_equals 3 - 2 (exec (: 3) (: 2))
  expect_equals 5 - 3 (exec (: 5) (: 3))

  x = exec (: 9)
    : 7
  expect_equals 9 - 7 x

  x = exec
    : 11
    : 7
  expect_equals 11 - 7 x

  x = exec (: 11)
    :
      3
  expect_equals 11 - 3 x


// -------------------------------

add_3_4:
  return 3 + (exec:  4)
add_3_r5:
  return 3 + (exec: return 5)
add_3_p p:
  return 3 + (exec:  p)
add_3_rp p:
  return 3 + (exec: return p)
add_3_l4:
  l := 4
  return 3 + (exec: l)
add_3_rl5:
  l := 5
  return 3 + (exec: return l)

exec [block]:
  return block.call

execx x [block]:
  return block.call x

exec2 [block]:
  return block.call 100 200

exec [b1] [b2]:
  return b1.call - b2.call

extract callback:
  return callback

class Tree:
  value := ?
  left := ?
  right := ?

  constructor .value .left .right:

  add v:
    insert_ v: return this
    throw "Shouldn't get here"

  insert_ v [block]:
    if v >= value:
      if right:
        right.insert_ v block
      else:
        right = Tree v null null
        block.call
        throw "Shouldn't get here"
    else:
      if left:
        left.insert_ v block
      else:
        left = Tree v null null
        block.call
        throw "Shouldn't get here"

  do [block]:
    if left: left.do block
    block.call value
    if right: right.do block

test_block_in_blocks:
  local0 := 400
  local1 := 99
  block := (: local0 + local1)
  expect_equals
    499
    exec: block.call  // References a block from within a block.

  // Same but one level down.
  exec:
    local2 := 358
    block2 := (: local0 - local2)
    expect_equals
      42
      exec: block2.call

  exec:
    local3 := 2020
    block3 := (: local0 + local1 + local3)
    expect_equals
      0
      exec
        block3
        : block3.call
