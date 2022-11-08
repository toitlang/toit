// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import .utils

main args:
  out := run_toitp args ["-d"]
  lines := out.split (platform == PLATFORM_WINDOWS ? "\r\n" : "\n")
  methods := lines.copy 1
  methods.filter --in_place: it != ""
  methods.map --in_place:
    colon_pos := it.index_of ": "
    space_pos := it.index_of " " (colon_pos + 2)
    it.copy (colon_pos + 2) space_pos

  // Two ClassA.test_foo next to each other.
  found_test_foo := false
  for i := 0; i < methods.size - 1; i++:
    if methods[i] == "ClassA.test_foo":
      expect methods[i + 1] == methods[i]
      found_test_foo = true
      break
  expect found_test_foo

  // ClassA.test_bar followed by ClassB.test_bar.
  found_test_bar := false
  for i := 0; i < methods.size - 1; i++:
    if methods[i] == "ClassA.test_bar":
      expect methods[i + 1] == "ClassB.test_bar"
      found_test_bar = true
      break
  expect found_test_bar
