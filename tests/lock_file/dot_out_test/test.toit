// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import ..dot-out-test.test as pre

foo: return "OK"

main:
  expect-equals "OK" pre.foo
