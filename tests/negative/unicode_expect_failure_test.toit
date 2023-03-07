// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test that long exceptions with Unicode characters in them don't break the
// error reporting machinery by being truncated in the middle of a UTF-8
// character.

import expect show *

main:
  expect_equals """
    ╒════╤════════╕
    │ no   header │
    ╘════╧════════╛
    """
    """
    ┌────┬────────┐
    │ no   header │
    └────┴────────┘
    """
