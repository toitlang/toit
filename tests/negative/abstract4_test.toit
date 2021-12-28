// Copyright (C) 2019 Toitware ApS. All rights reserved.

abstract class A:
  abstract foo

class B extends A:

abstract class C extends A:

main:
  (B).foo
  (C).foo
