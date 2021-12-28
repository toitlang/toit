// Copyright (C) 2018 Toitware ApS. All rights reserved.

class C extends A:
  foo .x: 42

class A:
  x / int := 0

class B extends A:
  foo .x: 499

main:
  (B).foo "str"
  (C).foo "str"
