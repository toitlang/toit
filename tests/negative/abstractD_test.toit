// Copyright (C) 2019 Toitware ApS. All rights reserved.

abstract class A:
  abstract foo x=unresolved

class B extends A:
  foo x:
    return x + unresolved

main:
