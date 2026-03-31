// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class A:
  field/int
/*
  @ def
    ^
  [def, storing-param, usage]
*/

  constructor .field:
/*
               @ storing-param
                 ^
  [def, storing-param, usage]
*/

main:
  a := A 42
  print a.field
/*
          @ usage
            ^
  [def, storing-param, usage]
*/
