// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import system

import .utils

main args:
  out := run-toitp args ["-l"]
  lines := out.split system.LINE-TERMINATOR

  found-foo-string := false
  found-int-literal := false
  found-float-literal := false
  for i := 1; i < lines.size; i++:
    line := lines[i]
    if line == "": continue
    colon-pos := line.index-of ": "
    literal := (line.copy (colon-pos + 1)).trim
    if literal == "foo": found-foo-string = true
    if literal == "81985529216486895": found-int-literal = true
    if literal.starts-with "12.34": found-float-literal = true
    if found-foo-string and found-int-literal and found-float-literal: break

  expect found-foo-string
  expect found-int-literal
  expect found-float-literal
