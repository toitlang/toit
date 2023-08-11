// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import .utils

main args:
  out := run-toitp args []
  required-output-snippets := [
    "snapshot: ",
    "- program:",
    "- method_table:",
    "- class_table:",
    "- primitives",
  ]
  required-output-snippets.do:
    expect (out.contains it)
