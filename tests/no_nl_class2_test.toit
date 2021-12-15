// Copyright (C) 2018 Toitware ApS. All rights reserved.

import expect show *

// Tests whether the parser correctly handles classes without new lines.

main:
  cls := No_new_line_class
  expect cls != null

// This class does not end with a new line.
class No_new_line_class: