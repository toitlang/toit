// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import crypto

main:
  bytes := crypto.random --size=0
  expect-equals 0 bytes.size

  bytes = crypto.random --size=1
  expect-equals 1 bytes.size

  bytes = crypto.random --size=10
  expect-equals 10 bytes.size
