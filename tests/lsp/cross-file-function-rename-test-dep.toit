// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Helper file: defines a top-level function used by the cross-file test.

helper-function x/int -> int:
/*
@ def
*/
/*
  ^
  [def, show, call]
*/
  return x + 1
