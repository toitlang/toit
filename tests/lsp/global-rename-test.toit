// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: renaming a global variable should find definition and usages.
my-global := 42
/*
@ def
^
  [def, use1, use2]
*/

use-it:
  return my-global
/*
         @ use1
         ^
  [def, use1, use2]
*/

main:
  use-it
  x := my-global
/*
       @ use2
       ^
  [def, use1, use2]
*/
