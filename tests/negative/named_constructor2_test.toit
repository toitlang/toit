// Copyright (C) 2019 Toitware ApS. All rights reserved.

class A:
  static foo x: return 499

class B extends A:
  constructor:
    super.foo  // Finds the static function.
    unresolved

main:
  b := B
