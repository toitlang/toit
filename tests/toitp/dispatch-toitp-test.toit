// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import .utils

main args:
  out := run-toitp args ["-d"]
  lines := out.split LINE-TERMINATOR
  methods := lines.copy 1
  methods.filter --in-place: it != ""
  methods.map --in-place:
    colon-pos := it.index-of ": "
    space-pos := it.index-of " " (colon-pos + 2)
    it.copy (colon-pos + 2) space-pos

  // Two ClassA.test_foo next to each other.
  found-test-foo := false
  for i := 0; i < methods.size - 1; i++:
    if methods[i] == "ClassA.test-foo":
      expect methods[i + 1] == methods[i]
      found-test-foo = true
      break
  expect found-test-foo

  // ClassA.test_bar followed by ClassB.test_bar.
  found-test-bar := false
  for i := 0; i < methods.size - 1; i++:
    if methods[i] == "ClassA.test-bar":
      expect methods[i + 1] == "ClassB.test-bar"
      found-test-bar = true
      break
  expect found-test-bar
