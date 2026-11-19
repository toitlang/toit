// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: named block parameter name, excluding '[--' and ']'.
block-fun [--on-done]:
/*
             ^
  on-done
*/
  on-done.call

main:
  block-fun --on-done=: null
