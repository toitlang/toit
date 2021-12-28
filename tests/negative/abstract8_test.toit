// Copyright (C) 2019 Toitware ApS. All rights reserved.

abstract class A:
  abstract foo:

class B extends A:
  foo: 42

main:
  B
