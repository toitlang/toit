// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

run fun/Lambda:
  fun.call

bar y/int z/int:
  expect_equals 42 y
  run:: y++
  expect_equals 43 y

  f := :: y++
  10.repeat: f.call

  expect_equals 53 y

  foo := 499
  run:: foo++
  expect_equals 500 foo

  f = :: foo++
  10.repeat: f.call

  expect_equals 510 foo

  gee := 499
  f = :: gee
  gee++
  expect_equals 500 f.call

  f = :: z
  z++
  expect_equals 999 z
  expect_equals 999 f.call

run2 f/Lambda:
  f.call.call

bar2 y/int z/int:
  expect_equals 42 y
  run2:: :: y++
  expect_equals 43 y

  f := :: :: y++
  10.repeat: f.call.call

  expect_equals 53 y

  foo := 499
  run2:: :: foo++
  expect_equals 500 foo

  f = :: :: foo++
  10.repeat: f.call.call

  expect_equals 510 foo

  gee := 499
  f = :: :: gee
  gee++
  expect_equals 500 f.call.call

  f = :: :: z
  z++
  expect_equals 999 z
  expect_equals 999 f.call.call

bar3 y/int z/int:
  expect_equals 42 y
  run::
    y++
    expect_equals 43 y
    run::
      y++
    expect_equals 44 y
  expect_equals 44 y

  foo := 42
  run::
    foo++
    expect_equals 43 foo
    run::
      foo++
    expect_equals 44 foo
  expect_equals 44 foo

  f := ::
    run::
      expect_equals 999 z
  z++
  run f
  expect_equals 999 z

main:
  bar 42 998
  bar2 42 998
  bar3 42 998
