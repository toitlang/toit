// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests that constant folding works.

This test is used by the optimization test (of the same name), which checks that
  there are no virtual calls left in the X_X_test functions. When changing the
  names of the functions (or adding new ones), it's necessary to change that test
  as well.
*/

import expect show *

int-int-test:
  expect-equals 499 400 + 99
  expect-equals 499 500 - 1
  expect-equals 99  33  * 3
  expect-equals 33  99  / 3
  expect-equals 2   7   % 5
  expect-equals 7   4   | 3
  expect-equals 2   6   & 3
  expect-equals 8   1  << 3
  expect-equals 0   1  << 64
  expect-equals 4   16 >> 2
  expect-equals -1  -1 >> 3
  expect-equals -1  -1 >> 63
  expect-equals -1  -1 >> 64
  expect-equals 0   99 >> 64
  expect-equals 3   -1 >>> 62
  expect-equals 1   -1 >>> 63
  expect-equals 0   -1 >>> 64
  expect 499 > 400
  expect (not 499 < 400)
  expect 499 >= 499
  expect 499 <= 499
  expect 400 < 499
  expect (not 400 > 499)
  expect 1 == 1
  expect (not 1 == 2)

float-int-test:
  expect-equals 499.0 400.0 + 99
  expect-equals 499.0 500.0 - 1
  expect-equals 99.0  33.0  * 3
  expect-equals 33.0  99.0  / 3
  expect-equals 2.0   7.0   % 5
  expect 499.0 > 400
  expect (not 499.0 < 400)
  expect 499.0 >= 499
  expect 499.0 <= 499
  expect 400.0 < 499
  expect (not 400.0 > 499)
  expect 1.0 == 1
  expect (not 1.0 == 2)
  expect -0.0 == 0

int-float-test:
  expect-equals 499.0 400 + 99.0
  expect-equals 499.0 500 - 1.0
  expect-equals 99.0  33  * 3.0
  expect-equals 33.0  99  / 3.0
  expect-equals 2.0   7   % 5.0
  expect 499 > 400.0
  expect (not 499 < 400.0)
  expect 499 >= 499.0
  expect 499 <= 499.0
  expect 400 < 499.0
  expect (not 400 > 499.0)
  expect 1 == 1.0
  expect (not 1 == 2.0)
  expect 0 == -0.0

float-float-test:
  expect-equals 499.0 400.0 + 99.0
  expect-equals 499.0 500.0 - 1.0
  expect-equals 99.0  33.0  * 3.0
  expect-equals 33.0  99.0  / 3.0
  expect-equals 2.0   7.0   % 5.0
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

not-test:
  expect (not null)
  expect (not false)
  expect-not (not 0)
  expect-not (not 1)
  expect-not (not "str")
  expect-not (not 0.0)
  expect-not (not float.NAN)
  expect-not (not float.INFINITY)
  expect (not (not true))

GLOBAL-TRUE ::= true
GLOBAL-FALSE ::= false

if-test:
  expect-not-null ("" ? 4 : null)  // @no-warn
  if "":  // @no-warn
    expect true
  else:
    throw "bad"
  expect (true ? true : false)
  expect-not (true ? false : true)
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

  if GLOBAL-TRUE:
    expect true
  else:
    unreachable

  if GLOBAL-FALSE:
    unreachable
  else:
    expect true

  if not GLOBAL-TRUE:
    unreachable
  else:
    expect true

  if not GLOBAL-FALSE:
    expect true
  else:
    unreachable

main:
  // The optimization test finds all functions by going through the static calls
  //   of main. As such, one can't call other functions than the test functions.
  int-int-test
  float-int-test
  int-float-test
  float-float-test
  not-test
  if-test
