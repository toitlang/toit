// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: parameter p1 at declaration site
param-test p1/int -> int:
/*
           ^
  p1
*/
  return p1 + 1

main:
  param-test 42
