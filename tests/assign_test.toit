// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

GLOBAL := 1

main:
  test_compound_add 42
  test_inc_dec 87

  n := 0
  expect_equals 9  (n += 9)
  expect_equals 9  n
  expect_equals 7  (n -= 2)
  expect_equals 7  n
  expect_equals 14 (n *= 2)
  expect_equals 14 n
  expect_equals 2  (n /= 7)
  expect_equals 2  n
  expect_equals 3  (n |= 1)
  expect_equals 3  n
  expect_equals 2  (n &= 6)
  expect_equals 2  n
  expect_equals 1  (n ^= 3)
  expect_equals 1  n
  expect_equals 8  (n <<= 3)
  expect_equals 8  n
  expect_equals 4  (n >>= 1)
  expect_equals 4  n

test_compound_add z:
  GLOBAL = 1
  GLOBAL += 2
  expect_equals 3 GLOBAL
  expect_equals 7 (GLOBAL += 4)
  expect_equals 7 GLOBAL

  box := Box 1
  box.value += 2
  expect_equals 3 box.value
  expect_equals 7 (box.value += 4)
  expect_equals 7 box.value

  box.test_compound_add

  box.value = 1
  i := -42
  box[i += 42] += 2
  expect_equals 3 box.value
  i = -87
  expect_equals 7 (box[i += 87] += 4)
  expect_equals 7 box.value

  x := 1
  x += 2
  expect_equals 3 x
  expect_equals 7 (x += 4)
  expect_equals 7 x

  y := 1
  exec: y += 2
  expect_equals 3 y
  expect_equals 7 (exec: y += 4)
  expect_equals 7 y

  z = 1
  z += 2
  expect_equals 3 z
  expect_equals 7 (z += 4)
  expect_equals 7 z

  z = 1
  exec: z += 2
  expect_equals 3 z
  expect_equals 7 (exec: z += 4)
  expect_equals 7 z

test_inc_dec z:
  GLOBAL = 0
  expect_equals 0 GLOBAL++
  expect_equals 1 GLOBAL
  expect_equals 2 (++GLOBAL)
  expect_equals 2 GLOBAL

  expect_equals 2 GLOBAL--
  expect_equals 1 GLOBAL
  expect_equals 0 (--GLOBAL)
  expect_equals 0 GLOBAL

  x := 0
  expect_equals 0 x++
  expect_equals 1 x
  expect_equals 2 (++x)
  expect_equals 2 x

  expect_equals 2 x--
  expect_equals 1 x
  expect_equals 0 (--x)
  expect_equals 0 x

  x = 0
  expect_equals 0 (exec: x++)
  expect_equals 1 x
  expect_equals 2 (exec: ++x)
  expect_equals 2 x

  expect_equals 2 (exec: x--)
  expect_equals 1 x
  expect_equals 0 (exec: --x)
  expect_equals 0 x

  z = 0
  expect_equals 0 z++
  expect_equals 1 z
  expect_equals 2 (++z)
  expect_equals 2 z

  expect_equals 2 z--
  expect_equals 1 z
  expect_equals 0 (--z)
  expect_equals 0 z

  z = 0
  expect_equals 0 (exec: z++)
  expect_equals 1 z
  expect_equals 2 (exec: ++z)
  expect_equals 2 z

  expect_equals 2 (exec: z--)
  expect_equals 1 z
  expect_equals 0 (exec: --z)
  expect_equals 0 z

  box := Box 0
  expect_equals 0 box.value++
  expect_equals 1 box.value
  expect_equals 2 (++box.value)
  expect_equals 2 box.value

  expect_equals 2 box.value--
  expect_equals 1 box.value
  expect_equals 0 (--box.value)
  expect_equals 0 box.value

  box = Box 0
  expect_equals 0 box[0]++
  expect_equals 1 box[0]
  expect_equals 2 (++box[0])
  expect_equals 2 box[0]

  expect_equals 2 box[0]--
  expect_equals 1 box[0]
  expect_equals 0 (--box[0])
  expect_equals 0 box[0]

  box.test_inc_dec

class Box:
  constructor .value:
  value := ?

  test_compound_add:
    value = 1
    value += 2
    expect_equals 3 value
    expect_equals 7 (value += 4)
    expect_equals 7 value

  test_inc_dec:
    value = 0
    expect_equals 0 value++
    expect_equals 1 value
    expect_equals 2 (++value)
    expect_equals 2 value

    expect_equals 2 value--
    expect_equals 1 value
    expect_equals 0 (--value)
    expect_equals 0 value

  operator [] n:
    expect_equals 0 n
    return value

  operator []= n val:
    expect_equals 0 n
    return value = val

exec [block]:
  return block.call
