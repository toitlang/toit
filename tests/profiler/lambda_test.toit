// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .utils
import expect show *

main args:
  lines := run args
  print lines
  expect (lines.first.starts_with "Profile of Lambda Profiler Test")

  expect_equals "[lambda] in foo" (lines[1].copy 7 35).trim
  expect_equals "[block] in [lambda] in bar" (lines[2].copy 7 35).trim
