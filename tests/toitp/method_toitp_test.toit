// Copyright (C) 2020 Toitware ApS. All rights reserved.

import expect show *
import .utils

main args:
  out := run_toitp args ["-m"]
  // lines := out.split "\n"
  found_methods := {}
  found_methods.add_all (extract_entries out --max_length=30)

  expected_methods := [
    "ClassA",
    "ClassA.named",
    "ClassA.static_method",
    "ClassA.field_a",
    "ClassA.field_a=",
    "ClassA.method_a",
    "ClassA.method_b",
    "ClassB",
    "ClassB.method_b",
    "global_method",
    "global_lazy_field",
    "Nested.block",
    "Nested.lambda",
    "[block] in Nested.block",
    "[lambda] in Nested.lambda",
  ]

  expected_methods.do:
    expect (found_methods.contains it)
