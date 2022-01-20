// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import .utils

main args:
  out := run_toitp args ["-c"]
  classes := {}
  classes.add_all (extract_entries out --max_length=10)

  expect (classes.contains "ClassA")
  expect (classes.contains "ClassB")
