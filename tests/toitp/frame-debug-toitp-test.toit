// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import .utils

main args:
  out := run-toitp args ["-m"]
  methods := extract-entries out --max-length=30
  expect (methods.contains "Fixture.inspect")
