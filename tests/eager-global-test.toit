// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests that eager globals aren't going through the lazy getter.

This test is used by the optimization test (of the same name).
*/

import expect show *

eager-global := 499

counter := 0
side x:
  counter++
  return x
lazy-global := side 42

eager-test:
  return eager-global

lazy-test:
  return lazy-global

main:
  expect-equals 499 eager-test
  expect-equals 42 lazy-test
  eager-global++
  lazy-global++
  expect-equals 500 eager-test
  expect-equals 43 lazy-test
  expect-equals 1 counter
