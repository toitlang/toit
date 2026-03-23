// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: named args at declaration
named-fun --my-flag/bool:
/*
             ^
  my-flag
*/
  return my-flag
/*
         ^
  my-flag
*/

main:
  named-fun --my-flag=true
