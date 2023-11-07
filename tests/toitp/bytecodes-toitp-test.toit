// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import .utils

test args filter:
  out := run-toitp args ["-bc"] --filter=filter
  lines := out.split LINE-TERMINATOR
  expect (lines.first.starts-with "Bytecodes for methods")

  expected-bytecodes := [
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
    "is interface *is-I",
    "as interface *is-I",
  ]

  lines-index := 2
  last-matched-line := null
  expected-bytecodes.do:
    while lines-index < lines.size and not lines[lines-index].contains it:
      lines-index++
    expect lines-index < lines.size
    last-matched-line = lines[lines-index]

  return last-matched-line

main args:
  last-matched-line := test args "bytecode-test"
  // Try again. This time using the absolute bci of the last line as filter.
  absolute-bci-start := last-matched-line.index-of "/"
  absolute-bci-end := last-matched-line.index-of "["
  absolute-bci-str := last-matched-line.copy (absolute-bci-start + 1) absolute-bci-end
  test args absolute-bci-str.trim
