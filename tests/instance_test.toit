// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  p := Point
  expect p != null
  expect p.x == 0
  expect p.y == 0

  p.x = 42
  p.y = 87
  expect p.x == 42
  expect p.y == 87
  expect p.sum == (42 + 87)

  p.x = 17
  p.y = 19
  expect p.x == 17
  expect p.y == 19

  t := null
  t = p.x = 99
  expect t == 99
  expect p.x == 99

  expect (p.init 2 3) == 5
  expect p.x == 2
  expect p.y == 3

  expect (p.init 4 5) == 9
  expect p.x == 4
  expect p.y == 5

  expect_equals (4 + 5) p.sum
  expect_equals (4 + 5 + 6) (p.sum 6)

  expect p.reset == 0
  expect p.x == 0
  expect p.y == 0


class Point:
  x := 0
  y := 0

  reset:
    return init 0 0

  init x_ y_:
    x = x_
    y = y_
    return sum

  sum:
    return x + y

  sum n:
    return x + y + n
