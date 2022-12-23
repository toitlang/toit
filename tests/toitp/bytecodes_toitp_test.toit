// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import .utils
/*
  0/ 264 [042] - allocate instance A
  2/ 266 [053] - invoke static A /Users/kasper/Toit/toitlang.org/toit/tests/toitp/bytecodes_input.toit:7:7
  6/ 270 [053] - invoke static A.foo /Users/kasper/Toit/toitlang.org/toit/tests/toitp/bytecodes_input.toit:8:3
 10/ 274 [042] - allocate instance B
 12/ 276 [053] - invoke static B /Users/kasper/Toit/toitlang.org/toit/tests/toitp/bytecodes_input.toit:10:7
 16/ 280 [053] - invoke static B.foo /Users/kasper/Toit/toitlang.org/toit/tests/toitp/bytecodes_input.toit:11:3
 20/ 284 [053] - invoke static bar /Users/kasper/Toit/toitlang.org/toit/tests/toitp/bytecodes_input.toit:13:1
 27/ 291 [035] - store global var G0
 31/ 295 [053] - invoke static confuse /Users/kasper/Toit/toitlang.org/toit/tests/toitp/bytecodes_input.toit:17:1
 34/ 298 [044] - is class A(43 - 44)
 38/ 302 [053] - invoke static confuse /Users/kasper/Toit/toitlang.org/toit/tests/toitp/bytecodes_input.toit:17:1
 41/ 305 [048] - as class A(43 - 44)
 45/ 309 [053] - invoke static confuse /Users/kasper/Toit/toitlang.org/toit/tests/toitp/bytecodes_input.toit:17:1
 48/ 312 [046] - is interface is-I
 52/ 316 [053] - invoke static confuse /Users/kasper/Toit/toitlang.org/toit/tests/toitp/bytecodes_input.toit:17:1
 55/ 319 [050] - as interface is-I

*/

test args filter:
  out := run_toitp args ["-bc", filter]
  lines := out.split LINE_TERMINATOR
  lines.do: print it
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
