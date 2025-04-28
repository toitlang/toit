// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import host.directory show cwd
import system

main:
  separator := system.platform == system.PLATFORM-WINDOWS ? "\\" : "/"
  full-path := [cwd, "tests", "program-path-test.toit"].join separator
  expect-equals full-path system.program-path
