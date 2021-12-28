// Copyright (C) 2019 Toitware ApS. All rights reserved.

class A:
  foo:
    return "A"

abstract class B extends A:
  abstract foo

class C extends B:

main:
  (C).foo
