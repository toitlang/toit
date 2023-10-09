// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

abstract mixin M1:
  abstract foo x y=null

class A extends Object with M1:

class B extends Object with M1:
  foo x:

class C:
  foo x y:

class D extends C with M1:

mixin M2:

mixin M3 extends M2 with M1:

main:
