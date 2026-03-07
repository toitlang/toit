// Copyright (C) 2026 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: renaming a global variable should find definition and usages.
my-global := 42
/*
^
  3
*/

use-it:
  return my-global
/*
         ^
  3
*/

main:
  use-it
  x := my-global
/*
       ^
  3
*/
