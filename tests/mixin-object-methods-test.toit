// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Simple test that the object methods are available on mixins.
*/

import expect show *

mixin M1:

class A extends Object with M1:

main:
  a/M1? := A
  if a == null: // Operator ==.
    throw "Bad"
  print a.stringify
