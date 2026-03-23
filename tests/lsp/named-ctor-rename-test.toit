// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class A:
  constructor.my-named-ctor:
/*
               ^
  2
*/

main:
  a := A.my-named-ctor
/*
            ^
  2
*/
