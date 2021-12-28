// Copyright (C) 2021 Toitware ApS. All rights reserved.

class A:
  constructor x:
  constructor x y=0:
  constructor x y --named=0: return A x

  constructor.foo:
  constructor.foo x=0:

  foo --arg=0:
  foo --arg --arg2=0:

  foo := 0

  static foo x=0 --arg:

  static bar x [block]:
  bar x [block] --named=0:
  static bar := 499
  bar x=0:

foo --arg=0:
foo --arg --arg2=0:

foo := 0

foo x=0 --arg:

bar x [block]:
bar x [block] --named=0:
bar := 499
bar x=0:

main:
