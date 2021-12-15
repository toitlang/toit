// Copyright (C) 2020 Toitware ApS. All rights reserved.

/**
Tests that constant folding works.

This test is used by the optimization test (of the same name), which checks that
  there are no virtual calls left in the X_X_test functions. When changing the
  names of the functions (or adding new ones), it's necessary to change that test
  as well.
*/

import expect show *

int_int_test:
  expect_equals 499 400 + 99
  expect_equals 499 500 - 1
  expect_equals 99  33  * 3
  expect_equals 33  99  / 3
  expect_equals 2   7   % 5
  expect_equals 7   4   | 3
  expect_equals 2   6   & 3
  expect_equals 8   1  << 3
  expect_equals 0   1  << 64
  expect_equals 4   16 >> 2
  expect_equals -1  -1 >> 3
  expect_equals -1  -1 >> 63
  expect_equals -1  -1 >> 64
  expect_equals 0   99 >> 64
  expect_equals 3   -1 >>> 62
  expect_equals 1   -1 >>> 63
  expect_equals 0   -1 >>> 64
  expect 499 > 400
  expect (not 499 < 400)
  expect 499 >= 499
  expect 499 <= 499
  expect 400 < 499
  expect (not 400 > 499)
  expect 1 == 1
  expect (not 1 == 2)

float_int_test:
  expect_equals 499.0 400.0 + 99
  expect_equals 499.0 500.0 - 1
  expect_equals 99.0  33.0  * 3
  expect_equals 33.0  99.0  / 3
  expect_equals 2.0   7.0   % 5
  expect 499.0 > 400
  expect (not 499.0 < 400)
  expect 499.0 >= 499
  expect 499.0 <= 499
  expect 400.0 < 499
  expect (not 400.0 > 499)
  expect 1.0 == 1
  expect (not 1.0 == 2)
  expect -0.0 == 0

int_float_test:
  expect_equals 499.0 400 + 99.0
  expect_equals 499.0 500 - 1.0
  expect_equals 99.0  33  * 3.0
  expect_equals 33.0  99  / 3.0
  expect_equals 2.0   7   % 5.0
  expect 499 > 400.0
  expect (not 499 < 400.0)
  expect 499 >= 499.0
  expect 499 <= 499.0
  expect 400 < 499.0
  expect (not 400 > 499.0)
  expect 1 == 1.0
  expect (not 1 == 2.0)
  expect 0 == -0.0

float_float_test:
  expect_equals 499.0 400.0 + 99.0
  expect_equals 499.0 500.0 - 1.0
  expect_equals 99.0  33.0  * 3.0
  expect_equals 33.0  99.0  / 3.0
  expect_equals 2.0   7.0   % 5.0
  expect 499.0 > 400.0
  expect (not 499.0 < 400.0)
  expect 499.0 >= 499.0
  expect 499.0 <= 499.0
  expect 400.0 < 499.0
  expect (not 400.0 > 499.0)
  expect 1.0 == 1.0
  expect (not 1.0 == 2.0)
  expect 0.0 == -0.0
  expect -0.0 == 0.0
  expect -0.0 == -0.0
  expect (identical -0.0 -0.0)
  expect (identical 0.0 (-0.0 + 0.0))
  expect (identical 0.0 (0.0 + -0.0))
  expect (not float.NAN == float.NAN)
  expect (identical float.NAN float.NAN)
  expect (identical float.NAN 0.0/0.0)
  expect float.INFINITY == 1.0/0.0

not_test:
  expect (not null)
  expect (not false)
  expect_not (not 0)
  expect_not (not 1)
  expect_not (not "str")
  expect_not (not 0.0)
  expect_not (not float.NAN)
  expect_not (not float.INFINITY)
  expect (not (not true))

GLOBAL_TRUE ::= true
GLOBAL_FALSE ::= false

if_test:
  expect_not_null ("" ? 4 : null)
  if "":
    expect true
  else:
    throw "bad"
  expect (true ? true : false)
  expect_not (true ? false : true)
  expect (null ? false : true)
  expect (null
    ? unreachable
    : null ? unreachable : true)

  if false:
    unreachable

  if true:
    expect true
  else:
    unreachable

  if GLOBAL_TRUE:
    expect true
  else:
    unreachable

  if GLOBAL_FALSE:
    unreachable
  else:
    expect true

  if not GLOBAL_TRUE:
    unreachable
  else:
    expect true

  if not GLOBAL_FALSE:
    expect true
  else:
    unreachable

main:
  // The optimization test finds all functions by going through the static calls
  //   of main. As such, one can't call other functions than the test functions.
  int_int_test
  float_int_test
  int_float_test
  float_float_test
  not_test
  if_test
