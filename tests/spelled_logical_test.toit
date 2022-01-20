// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

counter := 0
id x:
  counter++
  return x
id [x]:
  counter++
  return x.call

main:
  // Not:
  x := not true
  expect_equals false x

  x = not id true
  expect_equals false x

  x = not id: true
  expect_equals false x

  x = not false
  expect_equals true x

  x = not id false
  expect_equals true x

  x = not id: false
  expect_equals true x

  // And:
  x = true and true
  expect_equals true x
  x = true and false
  expect_equals false x
  x = false and true
  expect_equals false x
  x = false and false
  expect_equals false x

  counter = 0

  x = id true and id true
  expect_equals true x
  x = id true and id false
  expect_equals false x
  x = id false and id true
  expect_equals false x
  x = id false and id false
  expect_equals false x

  // Make sure the shortcuts worked.
  expect_equals 6 counter
  counter = 0

  x = id: true and id: true
  expect_equals true x
  x = id: true and id: false
  expect_equals false x
  x = id: false and id: true
  expect_equals false x
  x = id: false and id: false
  expect_equals false x

  // Make sure the shortcuts worked.
  expect_equals 6 counter
  counter = 0

  // Or:
  x = true or true
  expect_equals true x
  x = true or false
  expect_equals true x
  x = false or true
  expect_equals true x
  x = false or false
  expect_equals false x

  x = id true or id true
  expect_equals true x
  x = id true or id false
  expect_equals true x
  x = id false or id true
  expect_equals true x
  x = id false or id false
  expect_equals false x

  // Make sure the shortcuts worked.
  expect_equals 6 counter
  counter = 0

  x = id: true or id: true
  expect_equals true x
  x = id: true or id: false
  expect_equals true x
  x = id: false or id: true
  expect_equals true x
  x = id: false or id: false
  expect_equals false x

  // Make sure the shortcuts worked.
  expect_equals 6 counter
  counter = 0

  // Combinations
  x = true and not false and false or false and true or true
  expect_equals true x
  x = true and not false and false or false and true or false
  expect_equals false x

  x = id true and not id false and id false or id false and id true or id true
  expect_equals true x
  expect_equals 5 counter
  counter = 0

  x = id true and not id false and id false or id false and id true or id false
  expect_equals false x
  expect_equals 5 counter
  counter = 0

  x = id true
    and not id false
    and id false
    or id false
    and id true
    or id true
  expect_equals true x
  expect_equals 5 counter
  counter = 0

  x = id true
    and not id false
    and id false
    or id false
    and id true
    or id false
  expect_equals false x
  expect_equals 5 counter
  counter = 0

  x = id true
      and not id false
      and id false
    or id false
      and id true
    or id true
  expect_equals true x
  expect_equals 5 counter
  counter = 0

  x = id true
      and not id false
      and id false
    or id false
      and id true
    or id false
  expect_equals false x
  expect_equals 5 counter
  counter = 0

  x = true and id:
    false or true
      and id: false or true
  expect_equals true x

  x = true and id:
    false or true
      and id: false or false
  expect_equals false x
