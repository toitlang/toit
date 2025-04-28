// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  test-single
  test-multi
  test-outer
  test-recursive

test-single:
  x := null
  b := : id x
  x = 1
  b.call

test-multi:
  x := null
  b := : id x
  x = 1
  b.call
  x = "hest"
  b.call
  id x

test-outer:
  x := null
  b := : id x
  x = "hest"
  8.repeat:
    b.call
  2.repeat:
    inner := :
      x = it
      b.call
    inner.call 1
    id x
    inner.call 2.2
    id x
    inner.call true
    id x
  id x

test-recursive:
  foo 3: 42

foo n/int [block]:
  x := null
  if n == 0: return block.call
  foo n - 1:
    id x
    x = "hest"
    c := block.call
    // The current block can be invoked with x as an int,
    // because of the recursive call to the block.
    x = 123
    c += block.call
    id x
    return 1 + c
  unreachable

id x:
  return x

pick:
  return (random 100) < 50
