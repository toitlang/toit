// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .utils
import expect show *

main args:
  lines := run args
  print (lines.join "\n")
  expect (lines.first.starts_with "Profile of Profiler Test")

  expect_equals "foo" (lines[1].copy 7 30).trim
  expect_equals "[block] in bar" (lines[2].copy 7 30).trim
