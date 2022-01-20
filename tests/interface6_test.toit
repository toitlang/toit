// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

interface I1:
  foo x y=499 --named1 --named2=42 --named3=499
  bar x y=499 [block] --named1 --named2=42 --named3=499 [--b]

class A implements I1:
  foo x --named1:
  foo x --named1 --named2:
  foo x --named1 --named3:
  foo x --named1 --named2 --named3:
  foo x y --named1 --named2=42 --named3=499:

  bar x [block] --named1 [--b]:
  bar x [block] --named1 --named2 [--b]:
  bar x [block] --named1 --named3 [--b]:
  bar x [block] --named1 --named2 --named3 [--b]:
  bar x y [block] --named1 --named2=42 --named3=499 [--b]:

interface I2:
  foo x --named1
  foo x --named1 --named2
  foo x --named1 --named3
  foo x --named1 --named2 --named3
  foo x y --named1 --named2=42 --named3=499

  bar x [block] --named1 [--b]
  bar x [block] --named1 --named2 [--b]
  bar x [block] --named1 --named3 [--b]
  bar x [block] --named1 --named2 --named3 [--b]
  bar x y [block] --named1 --named2=42 --named3=499 [--b]

class B implements I2:
  foo x y=499 --named1 --named2=42 --named3=499:
  bar x y=499 [block] --named1 --named2=42 --named3=499 [--b]:

class C implements I1 I2:
  foo x y=499 --named1 --named2=42 --named3=499:
  bar x y=499 [block] --named1 --named2=42 --named3=499 [--b]:

class D implements I1 I2:
  foo x --named1:
  foo x --named1 --named2:
  foo x --named1 --named3:
  foo x --named1 --named2 --named3:
  foo x y --named1 --named2=42 --named3=499:

  bar x [block] --named1 [--b]:
  bar x [block] --named1 --named2 [--b]:
  bar x [block] --named1 --named3 [--b]:
  bar x [block] --named1 --named2 --named3 [--b]:
  bar x y [block] --named1 --named2=42 --named3=499 [--b]:

interface I3:
  method --arg1 --arg2=0
  method --arg2 --arg3=0
  method --arg3 --arg1=0

class E implements I3:
  method --arg1=0 --arg2=0 --arg3=0:

interface I4:
  method --arg1=0 --arg2=0 --arg3=0

class F implements I4:
  method --arg1 --arg2=0:
  method --arg2 --arg3=0:
  method --arg3 --arg1=0:
  method:
  method --arg1 --arg2 --arg3:

main:
  // This test just checks that there aren't any warnings or
  // errors when optional and non-optional methods interact
  // with each other for interface validation.
  a := A
  b := B
  c := C
  d := D
  e := E
  f := F
