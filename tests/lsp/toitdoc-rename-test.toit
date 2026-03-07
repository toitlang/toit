// Copyright (C) 2026 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: renaming a symbol also updates $references in toitdoc comments.

/// Uses $helper to do work.
/// Also mentions $helper again.
class MyWorker:
  run:
    helper

  helper:
/*
  ^
  4
*/
    return 42

main:
  w := MyWorker
  w.run
