// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

expect-as-check-failure [code]:
  expect-equals
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

static-e -> E: return F

wants-i x/I: null

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

  current-counter := counter
  x := null
  x = A as A
  expect-equals current-counter++ x.c
  x = B as A
  expect-equals current-counter++ x.c
  x = C as A
  expect-equals current-counter++ x.c
  x = D as A
  expect-equals current-counter++ x.c
  x = B as B
  expect-equals current-counter++ x.c
  x = C as B
  expect-equals current-counter++ x.c
  x = D as B
  expect-equals current-counter++ x.c
  x = D as C
  expect-equals current-counter++ x.c
  x = D as D
  expect-equals current-counter++ x.c

  expect-as-check-failure: A as B
  expect-as-check-failure: A as B
  expect-as-check-failure: A as E
  expect-as-check-failure: E as A
  expect-as-check-failure: E as D

  current-counter = counter
  expect-as-check-failure: side (A as B)
  current-counter++  // For the creation of 'A'
  expect-as-check-failure: side (A as B)
  current-counter++  // For the creation of 'A'
  expect-as-check-failure: side (A as E)
  current-counter++  // For the creation of 'A'
  expect-as-check-failure: side (E as A)
  current-counter++  // For the creation of 'E'
  expect-as-check-failure: side (E as D)
  current-counter++  // For the creation of 'E'
  expect-equals current-counter counter

  499 as int
  expect-equals 499 (499 as int)

  "foo" as string
  expect-equals "foo" ("foo" as string)

  current-counter = counter
  (side "foo") as string
  expect-equals (current-counter + 1) counter

  A as A
  B as A
  C as A
  D as A
  B as B
  C as B
  D as B
  D as C
  D as D

  current-counter = counter
  x = C as I
  expect-equals current-counter++ x.c
  x = D as I
  expect-equals current-counter++ x.c

  expect-as-check-failure: A as I
  expect-as-check-failure: B as I
  expect-as-check-failure: E as I
  current-counter = counter
  expect-as-check-failure: side (A as I)
  current-counter++  // For the creation of 'A'
  expect-as-check-failure: side (B as I)
  current-counter++  // For the creation of 'B'
  expect-as-check-failure: side (E as I)
  current-counter++  // For the creation of 'E'
  expect-equals current-counter counter

  e := static-e
  wants-i e as F
  wants-i e as any
