// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

// Tests whether the parser correctly handles classes without new lines.

main:
  cls := No-new-line-class
  expect cls != null

// This class does not end with a new line.
class No-new-line-class: