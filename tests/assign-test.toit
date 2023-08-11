// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

GLOBAL := 1

main:
  test-compound-add 42
  test-inc-dec 87

  n := 0
  expect-equals 9  (n += 9)
  expect-equals 9  n
  expect-equals 7  (n -= 2)
  expect-equals 7  n
  expect-equals 14 (n *= 2)
  expect-equals 14 n
  expect-equals 2  (n /= 7)
  expect-equals 2  n
  expect-equals 3  (n |= 1)
  expect-equals 3  n
  expect-equals 2  (n &= 6)
  expect-equals 2  n
  expect-equals 1  (n ^= 3)
  expect-equals 1  n
  expect-equals 8  (n <<= 3)
  expect-equals 8  n
  expect-equals 4  (n >>= 1)
  expect-equals 4  n

test-compound-add z:
  GLOBAL = 1
  GLOBAL += 2
  expect-equals 3 GLOBAL
  expect-equals 7 (GLOBAL += 4)
  expect-equals 7 GLOBAL

  box := Box 1
  box.value += 2
  expect-equals 3 box.value
  expect-equals 7 (box.value += 4)
  expect-equals 7 box.value

  box.test-compound-add

  box.value = 1
  i := -42
  box[i += 42] += 2
  expect-equals 3 box.value
  i = -87
  expect-equals 7 (box[i += 87] += 4)
  expect-equals 7 box.value

  x := 1
  x += 2
  expect-equals 3 x
  expect-equals 7 (x += 4)
  expect-equals 7 x

  y := 1
  exec: y += 2
  expect-equals 3 y
  expect-equals 7 (exec: y += 4)
  expect-equals 7 y

  z = 1
  z += 2
  expect-equals 3 z
  expect-equals 7 (z += 4)
  expect-equals 7 z

  z = 1
  exec: z += 2
  expect-equals 3 z
  expect-equals 7 (exec: z += 4)
  expect-equals 7 z

test-inc-dec z:
  GLOBAL = 0
  expect-equals 0 GLOBAL++
  expect-equals 1 GLOBAL
  expect-equals 2 (++GLOBAL)
  expect-equals 2 GLOBAL

  expect-equals 2 GLOBAL--
  expect-equals 1 GLOBAL

  x := 0
  expect-equals 0 x++
  expect-equals 1 x
  expect-equals 2 (++x)
  expect-equals 2 x

  expect-equals 2 x--
  expect-equals 1 x

  x = 0
  expect-equals 0 (exec: x++)
  expect-equals 1 x
  expect-equals 2 (exec: ++x)
  expect-equals 2 x

  expect-equals 2 (exec: x--)
  expect-equals 1 x

  z = 0
  expect-equals 0 z++
  expect-equals 1 z
  expect-equals 2 (++z)
  expect-equals 2 z

  expect-equals 2 z--
  expect-equals 1 z

  z = 0
  expect-equals 0 (exec: z++)
  expect-equals 1 z
  expect-equals 2 (exec: ++z)
  expect-equals 2 z

  expect-equals 2 (exec: z--)
  expect-equals 1 z

  box := Box 0
  expect-equals 0 box.value++
  expect-equals 1 box.value
  expect-equals 2 (++box.value)
  expect-equals 2 box.value

  expect-equals 2 box.value--
  expect-equals 1 box.value

  box = Box 0
  expect-equals 0 box[0]++
  expect-equals 1 box[0]
  expect-equals 2 (++box[0])
  expect-equals 2 box[0]

  expect-equals 2 box[0]--
  expect-equals 1 box[0]

  box.test-inc-dec

class Box:
  constructor .value:
  value := ?

  test-compound-add:
    value = 1
    value += 2
    expect-equals 3 value
    expect-equals 7 (value += 4)
    expect-equals 7 value

  test-inc-dec:
    value = 0
    expect-equals 0 value++
    expect-equals 1 value
    expect-equals 2 (++value)
    expect-equals 2 value

    expect-equals 2 value--
    expect-equals 1 value

  operator [] n:
    expect-equals 0 n
    return value

  operator []= n val:
    expect-equals 0 n
    return value = val

exec [block]:
  return block.call
