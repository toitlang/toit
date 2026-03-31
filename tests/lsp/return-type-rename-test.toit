// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: renaming a class from a return-type annotation.
class Foo:
/*    @ def */
  constructor:

make -> Foo:
/*
        @ return-type
         ^
  [def, return-type, constructor]
*/
  return Foo
/*       @ constructor */

main:
  make
