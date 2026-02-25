// Copyright (C) 2026 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: constant declaration and usage
MY-CONST ::= 42
/*
^
  MY-CONST
*/

use-const:
  return MY-CONST
/*
         ^
  MY-CONST
*/

main:
  use-const
