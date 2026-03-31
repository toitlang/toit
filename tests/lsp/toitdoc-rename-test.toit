// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: renaming a symbol also updates $references in toitdoc comments.

/// Uses $helper to do work. See also $helper.
/*                                     @ toitdoc-ref2 */
/*        @ toitdoc-ref1 */
class MyWorker:
  run:
    helper
/*  @ call */

  helper:
/*
  @ def
  ^
  [def, call, toitdoc-ref1, toitdoc-ref2]
*/
    return 42

main:
  w := MyWorker
  w.run
