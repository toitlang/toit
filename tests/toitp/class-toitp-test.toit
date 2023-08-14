// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import .utils

main args:
  out := run-toitp args ["-c"]
  classes := {}
  classes.add-all (extract-entries out --max-length=10)

  expect (classes.contains "ClassA")
  expect (classes.contains "ClassB")
