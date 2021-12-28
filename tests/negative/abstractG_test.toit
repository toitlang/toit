// Copyright (C) 2021 Toitware ApS. All rights reserved.

abstract class Abstract:
  abstract foo x y=499 --named1 --named2=42 --named3=499
  abstract bar x y=499 [block] --named1 --named2=42 --named3=499 [--b]

class A extends Abstract:
  foo x --named1:
  foo x --named1 --named2:
  foo x --named1 --named2 --named3:
  foo x y --named1 --named2=42 --named3=499:

  bar x [block] --named1 --named2 [--b]:
  bar x [block] --named1 --named3 [--b]:
  bar x [block] --named1 --named2 --named3 [--b]:
  bar x y [block] --named1 --named2=42 --named3=499 [--b]:

abstract class Abstract2:
  abstract foo x --named1
  abstract foo x --named1 --named2
  abstract foo x --named1 --named3
  abstract foo x --named1 --named2 --named3
  abstract foo x y --named1 --named2=42 --named3=499 --named4=11

  abstract bar x [block] --named1 [--b]
  abstract bar x [block] --named1 --named2 [--b]
  abstract bar x [block] --named1 --named3 [--b]
  abstract bar x [block] --named1 --named2 --named3 [--b]
  abstract bar x y [block] --named1 --named2=42 --named3=499 [--b] --named4=11

class B extends Abstract2:
  foo x y=499 --named1 --named2=42 --named3=499:
  bar x y=499 [block] --named1 --named2=42 --named3=499 [--b]:

main:
  a := A
  b := B
