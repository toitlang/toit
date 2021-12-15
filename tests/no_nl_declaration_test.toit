// Copyright (C) 2018 Toitware ApS. All rights reserved.

import expect show *

// Tests whether the parser correctly handles declarations without new lines.

main:
  expect no_new_line_declaration == "correct"

// This declaration does not end with a new line.
no_new_line_declaration := "correct"