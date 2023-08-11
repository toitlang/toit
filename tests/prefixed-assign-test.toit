// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import .prefixed-assign as prefix

main:
  prefix.x = 3
  expect-equals 3 prefix.x
  prefix.x++
  expect-equals 4 prefix.x
  prefix.x += 2
  expect-equals 6 prefix.x
