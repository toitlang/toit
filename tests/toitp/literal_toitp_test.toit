// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import .utils

main args:
  out := run_toitp args ["-l"]
  lines := out.split LINE_TERMINATOR

  found_foo_string := false
  found_int_literal := false
  found_float_literal := false
  for i := 1; i < lines.size; i++:
    line := lines[i]
    if line == "": continue
    colon_pos := line.index_of ": "
    literal := (line.copy (colon_pos + 1)).trim
    if literal == "foo": found_foo_string = true
    if literal == "81985529216486895": found_int_literal = true
    if literal.starts_with "12.34": found_float_literal = true
    if found_foo_string and found_int_literal and found_float_literal: break

  expect found_foo_string
  expect found_int_literal
  expect found_float_literal
