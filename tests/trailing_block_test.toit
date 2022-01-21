// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  simple
  gnarly

simple:
  a := List 3
  a[0] = "Hello"
  a[1] = "Cruel"
  a[2] = "Lars"
  a.do: | it | debug it

gnarly:
  x := null
  y := null

  do: 4
  do: 3; 4
  do:
    4

  x = do: 4
  x = do: 3; 4
  x = do:
    4

  y = x = do: 4
  y = x = do: 3; 4
  y = x = do:
    4

  expect (do: 4) == 123 + 4
  expect (do: 3; 5) == 123 + 5

  // --------------

  doo 7: 4
  doo 7: 3; 4
  doo 7:
    4

  x = doo 7: 4
  x = doo 7: 3; 4
  x = doo 7:
    4

  y = x = doo 7: 4
  y = x = doo 7: 3; 4
  y = x = doo 7:
    4

  expect (doo 7: 4) == 234 + 7 + 4
  expect (doo 8: 3; 5) == 234 + 8 + 5

  // --------------

  a := Foo

  a.do: 4
  a.do: 3; 4
  a.do:
    4

  x = a.do: 4
  x = a.do: 3; 4
  x = a.do:
    4

  y = x = a.do: 4
  y = x = a.do: 3; 4
  y = x = a.do:
    4

  expect (a.do: 4) == 345 + 4
  expect (a.do: 3; 5) == 345 + 5

  // --------------

  a.doo 7: 4
  a.doo 7: 3; 4
  a.doo 7:
    4

  x = a.doo 7: 4
  x = a.doo 7: 3; 4
  x = a.doo 7:
    4

  y = x = a.doo 7: 4
  y = x = a.doo 7: 3; 4
  y = x = a.doo 7:
    4

  expect (a.doo 7: 4) == 456 + 7 + 4
  expect (a.doo 8: 3; 5) == 456 + 8 + 5

do [b]:
  return 123 + b.call
doo x [b]:
  return 234 + x + b.call

class Foo:
  do [b]:
    return 345 + b.call
  doo x [b]:
    return 456 + x + b.call
