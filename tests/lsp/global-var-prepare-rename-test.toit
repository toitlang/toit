// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: global variable usage
my-global := 42
/*
^
  my-global
*/

use-it:
  return my-global
/*
         ^
  my-global
*/

main:
  use-it
