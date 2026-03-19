// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: prepareRename with cursor on $symbol inside a toitdoc comment.

/// Uses $helper to do work.
/*
          ^
  helper
*/
class MyWorker:
  run:
    helper

  helper:
    return 42

main:
  w := MyWorker
  w.run
