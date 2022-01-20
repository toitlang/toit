// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

// Tests whether the parser correctly handles functions without new lines.

main:
  expect no_new_line_function == "correct"

// This function does not end with a new line.
no_new_line_function:
  return "correct"