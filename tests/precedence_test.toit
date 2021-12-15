// Copyright (C) 2020 Toitware ApS. All rights reserved.

import expect show *

/*
In order:
  // Implicit: PRECEDENCE_DEFINITION
  PRECEDENCE_CONDITIONAL,
  PRECEDENCE_OR,
  PRECEDENCE_AND,
  PRECEDENCE_NOT,
  PRECEDENCE_CALL,
  PRECEDENCE_ASSIGNMENT,
  PRECEDENCE_EQUALITY,
  PRECEDENCE_RELATIONAL,
  PRECEDENCE_BIT_OR,
  PRECEDENCE_BIT_XOR,
  PRECEDENCE_BIT_AND,
  PRECEDENCE_BIT_SHIFT,
  PRECEDENCE_ADDITIVE,
  PRECEDENCE_MULTIPLICATIVE,
  PRECEDENCE_POSTFIX
*/

call0: return 12
call1 x: return x
call2 x y: return x
inc x: return x + 1

main:
  t1 := true or false ? 1 : 2
  expect_equals
    (true or false) ? 1 : 2
    t1

  t2 := true or false and false
  expect_equals
    true or (false and false)
    t2

  t3 := not false and false
  expect_equals
    (not false) and false
    t3

  t4 := call1 true and false
  expect_equals
    call1 (true and false)
    t4

  t5 := call2 499 == call0 499
  expect_equals
    call2 (499 == call0) 499
    t5

  t6 := 0 < 1 | 3
  expect_equals
    0 < (1 | 3)
    t6

  t7 := 1 | 2 ^ 3
  expect_equals
    1 | (2 ^ 3)
    t7

  t8 := 1 ^ 3 & 3
  expect_equals
    1 ^ (3 & 3)
    t8

  t9 := 1 & 3 << 1
  expect_equals
    1 & (3 << 1)
    t9

  tA := 1 << 1 + 1
  expect_equals
    1 << (1 + 1)
    tA

  tB := 1 + 1 * 2
  expect_equals
    1 + (1 * 2)
    tB

  x := 1
  tC := 1 * x++
  expect_equals 1 tC
  expect_equals 2 x
