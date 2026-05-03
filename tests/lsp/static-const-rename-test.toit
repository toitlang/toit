// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class A:
  static MY-CONST ::= 42
/*
         @ def
           ^
  [def, usage]
*/

main:
  print A.MY-CONST
/*
          @ usage
            ^
  [def, usage]
*/
