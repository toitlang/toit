// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  test-nested-block-params
  test-random-in-block
  test-non-local-return
  test-update-local-from-block
  test-update-parameter-from-block null
  test-nested-blocks 1
  test-nested-blocks 2
  expect test-return-from-nested-blocks == 42
  test-passing-too-many-args
  test-multiple-blocks
  test-block-in-blocks

  sum := 0
  [ 2, 3, 5, 7 ].do: sum += it
  expect sum == 2 + 3 + 5 + 7

  // Test that we can access outer locals where the
  // number of arguments passed to the various blocks and
  // the associated exec lambdas differ.
  i := 42
  j := exec:
    exec2: | x y | i
  expect-equals 42 j

  expect-equals 42 (extract:: 42).call
  expect-equals 87 (extract:: 87).call
  expect-equals sum (extract:: sum).call
  expect-equals
    7 + 3 + 4 - (1 + 2)
    (funky 7).call
  expect-equals 4
    (extract:: it + 1).call 3
  expect-equals 3
    (extract:: | a b | a - b).call 7 4

funky n:
  x := 1 + 2
  y := 3 + 4
  return extract:: n + y - x

test-random-in-block:
  result := exec:
    random
  print result

test-non-local-return:
  tree := Tree random null null
  for i := 0; i <= 25; i++: tree.add random
  tree.do: print it

  expect-equals 7 add-3-4
  expect-equals 5 add-3-r5
  expect-equals 8 (add-3-p 5)
  expect-equals 6 (add-3-rp 6)
  expect-equals 7 add-3-l4
  expect-equals 5 add-3-rl5

test-update-local-from-block:
  n := 0
  exec: n = 42
  expect-equals 42 n
  exec: n = 87
  expect-equals 87 n

test-update-parameter-from-block n:
  exec: n = 42
  expect-equals 42 n
  exec: n = 87
  expect-equals 87 n

test-nested-blocks x:
  org := x
  y := 4
  exec:
    z := x + y
    exec:
      y = z + x
      x = 4
  expect-equals 4 x
  expect-equals (org + 4 + org) y

test-nested-block-params:
  execx 7: | n | expect-equals 7 n
  execx 8: | n | expect-equals 8 n
  execx 9: | n | exec: expect-equals 9 n
  execx 10: | n |
    n = 11
    expect-equals 11 n
  execx 11:
    | n |
    exec: n = 12
    expect-equals 12 n

test-return-from-nested-blocks:
  exec:
    exec:
      return 42
  unreachable


invoke-lambda f:
  return f.call

invoke-lambda x f:
  return f.call x

invoke-lambda x y f:
  return f.call x y

invoke-block [b]:
  return b.call

invoke-block x [b]:
  return b.call x

invoke-block x y [b]:
  return b.call x y

test-passing-too-many-args:
  x := false
  execx 5: x = true
  expect x

  exec2: x = it
  expect-equals 100 x

  expect-equals 499 (invoke-lambda 0:: 499)
  expect-equals 499 (invoke-block 0: 499)
  expect-equals 42 (invoke-lambda 42 2:: it)
  expect-equals 42 (invoke-block 42 2: it)

test-multiple-blocks:
  x := 0
  expect-equals 3 - 2 (exec (: 3) (: 2))
  expect-equals 5 - 3 (exec (: 5) (: 3))

  x = exec (: 9)
    : 7
  expect-equals 9 - 7 x

  x = exec
    : 11
    : 7
  expect-equals 11 - 7 x

  x = exec (: 11)
    :
      3
  expect-equals 11 - 3 x


// -------------------------------

add-3-4:
  return 3 + (exec:  4)
add-3-r5:
  return 3 + (exec: return 5)
add-3-p p:
  return 3 + (exec:  p)
add-3-rp p:
  return 3 + (exec: return p)
add-3-l4:
  l := 4
  return 3 + (exec: l)
add-3-rl5:
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

test-block-in-blocks:
  local0 := 400
  local1 := 99
  block := (: local0 + local1)
  expect-equals
    499
    exec: block.call  // References a block from within a block.

  // Same but one level down.
  exec:
    local2 := 358
    block2 := (: local0 - local2)
    expect-equals
      42
      exec: block2.call

  exec:
    local3 := 2020
    block3 := (: local0 + local1 + local3)
    expect-equals
      0
      exec
        block3
        : block3.call
