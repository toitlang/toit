// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import .utils

main args:
  out := run_toitp args []
  required_output_snippets := [
    "snapshot: ",
    "- program:",
    "- method_table:",
    "- class_table:",
    "- primitives",
  ]
  required_output_snippets.do:
    expect (out.contains it)
