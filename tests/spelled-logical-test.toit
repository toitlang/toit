// Copyright (C) 2019 Toitware ApS.
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
  expect-equals false x

  x = not id true
  expect-equals false x

  x = not id: true
  expect-equals false x

  x = not false
  expect-equals true x

  x = not id false
  expect-equals true x

  x = not id: false
  expect-equals true x

  // And:
  x = true and true
  expect-equals true x
  x = true and false
  expect-equals false x
  x = false and true
  expect-equals false x
  x = false and false
  expect-equals false x

  counter = 0

  x = id true and id true
  expect-equals true x
  x = id true and id false
  expect-equals false x
  x = id false and id true
  expect-equals false x
  x = id false and id false
  expect-equals false x

  // Make sure the shortcuts worked.
  expect-equals 6 counter
  counter = 0

  x = id: true and id: true
  expect-equals true x
  x = id: true and id: false
  expect-equals false x
  x = id: false and id: true
  expect-equals false x
  x = id: false and id: false
  expect-equals false x

  // Make sure the shortcuts worked.
  expect-equals 6 counter
  counter = 0

  // Or:
  x = true or true
  expect-equals true x
  x = true or false
  expect-equals true x
  x = false or true
  expect-equals true x
  x = false or false
  expect-equals false x

  x = id true or id true
  expect-equals true x
  x = id true or id false
  expect-equals true x
  x = id false or id true
  expect-equals true x
  x = id false or id false
  expect-equals false x

  // Make sure the shortcuts worked.
  expect-equals 6 counter
  counter = 0

  x = id: true or id: true
  expect-equals true x
  x = id: true or id: false
  expect-equals true x
  x = id: false or id: true
  expect-equals true x
  x = id: false or id: false
  expect-equals false x

  // Make sure the shortcuts worked.
  expect-equals 6 counter
  counter = 0

  // Combinations
  x = true and not false and false or false and true or true
  expect-equals true x
  x = true and not false and false or false and true or false
  expect-equals false x

  x = id true and not id false and id false or id false and id true or id true
  expect-equals true x
  expect-equals 5 counter
  counter = 0

  x = id true and not id false and id false or id false and id true or id false
  expect-equals false x
  expect-equals 5 counter
  counter = 0

  x = id true
    and not id false
    and id false
    or id false
    and id true
    or id true
  expect-equals true x
  expect-equals 5 counter
  counter = 0

  x = id true
    and not id false
    and id false
    or id false
    and id true
    or id false
  expect-equals false x
  expect-equals 5 counter
  counter = 0

  x = id true
      and not id false
      and id false
    or id false
      and id true
    or id true
  expect-equals true x
  expect-equals 5 counter
  counter = 0

  x = id true
      and not id false
      and id false
    or id false
      and id true
    or id false
  expect-equals false x
  expect-equals 5 counter
  counter = 0

  x = true and id:
    false or true
      and id: false or true
  expect-equals true x

  x = true and id:
    false or true
      and id: false or false
  expect-equals false x
