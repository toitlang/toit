// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

interface I1:
  foo x y=499 --named1 --named2=42 --named3=499
  bar x y=499 [block] --named1 --named2=42 --named3=499 [--b]

class A implements I1:
  foo x --named1:
  foo x --named1 --named2:
  foo x --named1 --named2 --named3:
  foo x y --named1 --named2=42 --named3=499:

  bar x [block] --named1 --named2 [--b]:
  bar x [block] --named1 --named3 [--b]:
  bar x [block] --named1 --named2 --named3 [--b]:
  bar x y [block] --named1 --named2=42 --named3=499 [--b]:

interface I2:
  foo x --named1
  foo x --named1 --named2
  foo x --named1 --named3
  foo x --named1 --named2 --named3
  foo x y --named1 --named2=42 --named3=499 --named4=11

  bar x [block] --named1 [--b]
  bar x [block] --named1 --named2 [--b]
  bar x [block] --named1 --named3 [--b]
  bar x [block] --named1 --named2 --named3 [--b]
  bar x y [block] --named1 --named2=42 --named3=499 [--b] --named4=11

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

main:
  a := A
  b := B
  c := C
  d := D
