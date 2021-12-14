// Copyright (C) 2018 Toitware ApS. All rights reserved.

import expect show *

// Tests whether the parser correctly handles functions without new lines.

main:
  expect no_new_line_function == "correct"

// This function does not end with a new line.
no_new_line_function:
  return "correct"