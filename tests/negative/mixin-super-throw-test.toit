// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

mixin M1:
  constructor:
    throw "foo"

mixin M2:
mixin M3:
mixin M4:

class A extends Object with M1 M2 M3 M4:

main:
  a := A
