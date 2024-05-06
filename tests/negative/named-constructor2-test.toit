// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class A:
  static foo x: return 499

class B extends A:
  constructor:
    super.foo  // Finds the static function.
    unresolved

main:
  b := B
