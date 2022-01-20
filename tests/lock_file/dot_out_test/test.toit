// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import ..dot_out_test.test as pre

foo: return "OK"

main:
  expect_equals "OK" pre.foo
