// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import .utils

test args filter:
  out := run_toitp args ["-bc", filter]
  lines := out.split LINE_TERMINATOR
  expect (lines.first.starts_with "Bytecodes for methods")

  expected_bytecodes := [
    "allocate instance A",
    "invoke static A",
    "invoke static A.foo",
    "invoke virtual foo",
    "allocate instance B",
    "invoke static B",
    "invoke static B.foo",
    "invoke virtual foo",
    "invoke static bar",
    "store global var",
    "is class A",
    "as class A",
    "is interface is-I",
    "as interface is-I",
  ]

  lines_index := 2
  last_matched_line := null
  expected_bytecodes.do:
    while lines_index < lines.size and not lines[lines_index].contains it:
      lines_index++
    expect lines_index < lines.size
    last_matched_line = lines[lines_index]

  return last_matched_line

main args:
  last_matched_line := test args "bytecode_test"
  // Try again. This time using the absolute bci of the last line as filter.
  absolute_bci_start := last_matched_line.index_of "/"
  absolute_bci_end := last_matched_line.index_of "["
  absolute_bci_str := last_matched_line.copy (absolute_bci_start + 1) absolute_bci_end
  test args absolute_bci_str.trim
