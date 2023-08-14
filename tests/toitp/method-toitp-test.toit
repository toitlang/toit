// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import .utils

main args:
  out := run-toitp args ["-m"]
  // lines := out.split "\n"
  found-methods := {}
  found-methods.add-all (extract-entries out --max-length=30)

  expected-methods := [
    "ClassA",
    "ClassA.named",
    "ClassA.static-method",
    "ClassA.field-a",
    "ClassA.field-a=",
    "ClassA.method-a",
    "ClassA.method-b",
    "ClassB",
    "ClassB.method-b",
    "global-method",
    "global-lazy-field",
    "Nested.block",
    "Nested.lambda",
    "[block] in Nested.block",
    "[lambda] in Nested.lambda",
  ]

  expected-methods.do:
    expect (found-methods.contains it)
