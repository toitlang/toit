// Copyright (C) 2019 Toitware ApS. All rights reserved.

abstract class A:
  abstract foo

class B:
  foo:
    return super

main:
  (B).foo
