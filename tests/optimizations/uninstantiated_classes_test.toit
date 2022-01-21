// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .utils
import ...tools.snapshot show *
import expect show *
import host.directory

main args:
  test_path := directory.realpath "$directory.cwd/../uninstantiated_classes_test.toit"

  snap := run args --entry_path=test_path
  program := snap.decode

  saw_class_B := false
  saw_class_C := false
  program.class_tags.size.repeat:
    name := program.class_name_for it
    expect_not name == "A"
    if name == "B": saw_class_B = true
    if name == "C": saw_class_C = true
  expect saw_class_B
  expect saw_class_C

  // The following tests that the overridden methods are not compiled, but
  //   also, that we have the correct names for all methods.
  methods := extract_methods program [
    "A.foo", "A.bar", "A.foo",
    "B.foo", "B.bar", "B.gee",
    "C.foo", "C.bar", "C.gee",
  ]
  expected_non_existing := ["A.bar", "C.gee"]
  methods.do: |name method|
    if method == null:
      expect (expected_non_existing.contains name)
