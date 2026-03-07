// Copyright (C) 2026 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: renaming a top-level function across files.

import .cross-file-function-rename-test-dep show helper-function

main:
  helper-function 42
/*
  ^
  3
*/
