// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import .import4-a show foo
import .import4-b  // Not showing 'foo'

main:
  expect-equals "a" foo
