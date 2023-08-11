// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .utils
import ...tools.snapshot show *
import expect show *
import host.directory

main args:
  test-path := directory.realpath "$directory.cwd/../uninstantiated-classes-test.toit"

  snap := run args --entry-path=test-path
  program := snap.decode

  saw-class-B := false
  saw-class-C := false
  program.class-tags.size.repeat:
    name := program.class-name-for it
    expect-not name == "A"
    if name == "B": saw-class-B = true
    if name == "C": saw-class-C = true
  expect saw-class-B
  expect saw-class-C

  // The following tests that the overridden methods are not compiled, but
  //   also, that we have the correct names for all methods.
  methods := extract-methods program [
    "A.foo", "A.bar", "A.foo",
    "B.foo", "B.bar", "B.gee",
    "C.foo", "C.bar", "C.gee",
  ]
  expected-non-existing := ["A.bar", "C.gee"]
  methods.do: |name method|
    if method == null:
      expect (expected-non-existing.contains name)
