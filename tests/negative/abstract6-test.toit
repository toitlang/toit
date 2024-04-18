// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class A:
  foo:
    return "A"

abstract class B extends A:
  abstract foo

class C extends B:

mixin M1:
  foo:

abstract mixin M2 extends M1:
  abstract foo

main:
  (C).foo
  unresolved
