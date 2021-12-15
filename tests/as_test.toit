// Copyright (C) 2018 Toitware ApS. All rights reserved.

import expect show *

expect_as_check_failure [code]:
  expect_equals
    "AS_CHECK_FAILED"
    catch code

counter := 0

interface I:

class A:
  c ::= counter++

class B extends A:

class C extends B implements I:

class D extends C:

class E:
  c ::= counter++

class F extends E implements I:

static_e -> E: return F

wants_i x/I: null

side x:
  counter++
  return x

main:
  A as A
  B as A
  C as A
  D as A
  B as B
  C as B
  D as B
  D as C
  D as D

  a := A
  a as A

  current_counter := counter
  x := null
  x = A as A
  expect_equals current_counter++ x.c
  x = B as A
  expect_equals current_counter++ x.c
  x = C as A
  expect_equals current_counter++ x.c
  x = D as A
  expect_equals current_counter++ x.c
  x = B as B
  expect_equals current_counter++ x.c
  x = C as B
  expect_equals current_counter++ x.c
  x = D as B
  expect_equals current_counter++ x.c
  x = D as C
  expect_equals current_counter++ x.c
  x = D as D
  expect_equals current_counter++ x.c

  expect_as_check_failure: A as B
  expect_as_check_failure: A as B
  expect_as_check_failure: A as E
  expect_as_check_failure: E as A
  expect_as_check_failure: E as D

  current_counter = counter
  expect_as_check_failure: side (A as B)
  current_counter++  // For the creation of 'A'
  expect_as_check_failure: side (A as B)
  current_counter++  // For the creation of 'A'
  expect_as_check_failure: side (A as E)
  current_counter++  // For the creation of 'A'
  expect_as_check_failure: side (E as A)
  current_counter++  // For the creation of 'E'
  expect_as_check_failure: side (E as D)
  current_counter++  // For the creation of 'E'
  expect_equals current_counter counter

  499 as int
  expect_equals 499 (499 as int)

  "foo" as string
  expect_equals "foo" ("foo" as string)

  current_counter = counter
  (side "foo") as string
  expect_equals (current_counter + 1) counter

  A as A
  B as A
  C as A
  D as A
  B as B
  C as B
  D as B
  D as C
  D as D

  current_counter = counter
  x = C as I
  expect_equals current_counter++ x.c
  x = D as I
  expect_equals current_counter++ x.c

  expect_as_check_failure: A as I
  expect_as_check_failure: B as I
  expect_as_check_failure: E as I
  current_counter = counter
  expect_as_check_failure: side (A as I)
  current_counter++  // For the creation of 'A'
  expect_as_check_failure: side (B as I)
  current_counter++  // For the creation of 'B'
  expect_as_check_failure: side (E as I)
  current_counter++  // For the creation of 'E'
  expect_equals current_counter counter

  e := static_e
  wants_i e as F
  wants_i e as any
