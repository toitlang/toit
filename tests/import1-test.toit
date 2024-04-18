// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import .import1-a

main:
  expect-equals 42 a
  expect-equals 87 b
