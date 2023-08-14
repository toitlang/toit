// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

other := 42
counter := 0

global-accessor:
  counter++
  return other
global-accessor= x:
  counter++
  other = x + 1

main:
  expect-equals 42 other
  expect-equals 42 global-accessor
  expect-equals 1 counter
  expect-equals 42 global-accessor++
  expect-equals 44 other
  expect-equals 44 global-accessor
  expect-equals 4 counter
  global-accessor *= 2
  expect-equals 89 other
  expect-equals 89 global-accessor
  expect-equals 7 counter
