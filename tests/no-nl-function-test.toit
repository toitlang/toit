// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

// Tests whether the parser correctly handles functions without new lines.

main:
  expect no-new-line-function == "correct"

// This function does not end with a new line.
no-new-line-function:
  return "correct"