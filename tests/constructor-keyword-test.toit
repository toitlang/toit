// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

class A:
  field := ?
  constructor:
    field = 1
  constructor x:
    field = x
  constructor .field y:
  
  constructor.named:
    field = 1000
  constructor.named x:
    field = 1000 + x
  constructor.named .field y:  

  constructor fac tor y:
    return A 2000
  constructor.factory:
    return A 2001

main:
  expect-equals 1 (A).field
  expect-equals 2 (A 2).field
  expect-equals 3 (A 3 4).field

  expect-equals 1000 A.named.field
  expect-equals 1002 (A.named 2).field
  expect-equals 1003 (A.named 1003 4).field

  expect-equals 2000 (A 1 2 3).field
  expect-equals 2001 A.factory.field
