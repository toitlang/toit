// Copyright (C) 2019 Toitware ApS. All rights reserved.

import expect show *

import math

test_constants:
  // Here, we used Wolfram Alpha as source.
  expect_equals 3.1415926535897932384626433832795028841971693993751058209749
    math.PI

  expect_equals 2.7182818284590452353602874713526624977572470936999595749669
    math.E

  expect_equals 0.6931471805599453094172321214581765680755001343602552541206
    math.LN2

  expect_equals 2.3025850929940456840179914546843642076011014886287729760333
    math.LN10

  expect_equals 1.4426950408889634073599246810018921374266459541529859341354
    math.LOG2E

  expect_equals 0.4342944819032518276511289189166050822943970058036665661144
    math.LOG10E

  expect_equals 0.7071067811865475244008443621048490392848359376884740365883
    math.SQRT1_2

  expect_equals 1.4142135623730950488016887242096980785696718753769480731766
    math.SQRT2

main:
  test_constants

  expect_equals
    0.0
    math.sin 0.0

  expect_equals
    1.0
    math.cos 0.0

  expect_equals
    4.0
    math.pow 2.0 2.0

  expect_equals
    0.0
    math.sin 0

  expect_equals
    1.0
    math.cos 0

  expect_equals
    4.0
    math.pow 2 2

  expect (1.0 - (math.log math.E)).abs < 0.00000000001

  point := math.Point3f 1 2 3
  expect_equals 1 point.x
  expect_equals 2 point.y
  expect_equals 3 point.z

  bytes := point.to_byte_array
  point = math.Point3f.deserialize bytes
  expect_equals 1 point.x
  expect_equals 2 point.y
  expect_equals 3 point.z

  result := -point
  expect_equals -1 result.x
  expect_equals -2 result.y
  expect_equals -3 result.z

  result = result.abs
  expect_equals 1 result.x
  expect_equals 2 result.y
  expect_equals 3 result.z

  other_point := math.Point3f 0.5 1.5 2.5
  result = point + other_point
  expect_equals 1.5 result.x
  expect_equals 3.5 result.y
  expect_equals 5.5 result.z

  result = point - other_point
  expect_equals 0.5 result.x
  expect_equals 0.5 result.y
  expect_equals 0.5 result.z

  result = point * 2
  expect_equals 2 result.x
  expect_equals 4 result.y
  expect_equals 6 result.z

  result = point / 2
  expect_equals 0.5 result.x
  expect_equals 1   result.y
  expect_equals 1.5 result.z
