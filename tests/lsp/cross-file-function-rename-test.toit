// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: renaming a top-level function across files.

import .cross-file-function-rename-test-dep show helper-function
/*                                               @ show */

main:
  helper-function 42
/*@ call */
/*
  ^
  [def, show, call]
*/
