// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import .static2-test as p

main:
  expect-equals 499 (p.A.foo 499)
  expect-equals 33 p.A.bar
  p.A.bar++
  expect-equals 34 p.A.bar
  p.A.bar += 2
  expect-equals 36 p.A.bar
