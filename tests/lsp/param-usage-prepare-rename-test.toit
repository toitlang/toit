// Copyright (C) 2026 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: parameter usage (not declaration)
param-usage p1/int -> int:
  return p1 + 1
/*
         ^
  p1
*/

main:
  param-usage 42
