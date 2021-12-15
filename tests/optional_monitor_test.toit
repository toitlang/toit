// Copyright (C) 2019 Toitware ApS. All rights reserved.

import expect show *

counter := 0

side:
  counter++

monitor MyMonitor:
  foo expected arg=side:
    yield
    sleep --ms=1
    expect_equals expected counter

  bar expected --arg=side:
    yield
    sleep --ms=1
    expect_equals expected counter

  bar gee=side --arg=side --expected:
    yield
    sleep --ms=1
    expect_equals expected counter

main:
  m := MyMonitor
  m.foo 1
  expect_equals 1 counter
  m.foo 2

  m.bar 3
  expect_equals 3 counter
  m.bar 4

  m.bar --expected=6
  expect_equals 6 counter
  m.bar --expected=8
