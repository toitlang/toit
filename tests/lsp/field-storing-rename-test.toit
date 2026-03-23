// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class A:
  field/int
/*
    ^
  3
*/

  constructor .field:
/*
                 ^
  3
*/

main:
  a := A 42
  print a.field
/*
            ^
  3
*/
