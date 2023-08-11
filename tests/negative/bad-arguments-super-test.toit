// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class A:
  foo x y:

class B extends A:

main:
  b := B
  b.foo
  unresolved
