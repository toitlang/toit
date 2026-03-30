// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: renaming a constant should find definition and usages.
MY-CONST ::= 100
/*
@ def
*/
/*
^
  [def, usage]
*/

use-const -> int:
  return MY-CONST
/*       @ usage */
/*
         ^
  [def, usage]
*/

main:
  use-const
