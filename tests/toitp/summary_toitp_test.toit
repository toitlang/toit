// Copyright (C) 2020 Toitware ApS. All rights reserved.

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
