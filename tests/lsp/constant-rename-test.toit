// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: renaming a constant should find definition and usages.
MY-CONST ::= 100
/*
^
  2
*/

use-const -> int:
  return MY-CONST
/*
         ^
  2
*/

main:
  use-const
