// Copyright (C) 2020 Toitware ApS. All rights reserved.

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
  expect_equals 1 (A).field
  expect_equals 2 (A 2).field
  expect_equals 3 (A 3 4).field

  expect_equals 1000 A.named.field
  expect_equals 1002 (A.named 2).field
  expect_equals 1003 (A.named 1003 4).field

  expect_equals 2000 (A 1 2 3).field
  expect_equals 2001 A.factory.field
