// Copyright (C) 2019 Toitware ApS. All rights reserved.

abstract class A:
  abstract foo
  abstract bar

abstract class B extends A:
  foo:
    return 42

class C extends B:

main:
  c := C
