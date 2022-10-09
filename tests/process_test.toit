// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  spawn:: expect_equals Process.PRIORITY_NORMAL Process.current.priority
  spawn --priority=100:: expect_equals 100 Process.current.priority
  spawn --priority=255:: expect_equals 255 Process.current.priority
