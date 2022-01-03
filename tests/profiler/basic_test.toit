// Copyright (C) 2020 Toitware ApS. All rights reserved.

import .utils
import expect show *

main args:
  lines := run args
  expect (lines.first.starts_with "Profile of Profiler Test")

  expect_equals "foo" (lines[1].copy 7 30).trim
  expect_equals "[block] in bar" (lines[2].copy 7 30).trim
