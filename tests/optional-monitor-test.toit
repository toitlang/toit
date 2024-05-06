// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

counter := 0

side:
  counter++

monitor MyMonitor:
  foo expected arg=side:
    yield
    sleep --ms=1
    expect-equals expected counter

  bar expected --arg=side:
    yield
    sleep --ms=1
    expect-equals expected counter

  bar gee=side --arg=side --expected:
    yield
    sleep --ms=1
    expect-equals expected counter

main:
  m := MyMonitor
  m.foo 1
  expect-equals 1 counter
  m.foo 2

  m.bar 3
  expect-equals 3 counter
  m.bar 4

  m.bar --expected=6
  expect-equals 6 counter
  m.bar --expected=8
