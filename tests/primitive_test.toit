// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

foo x="":
  #primitive.core.string_hash_code

main:
  expect_equals "str".hash_code (foo "str")
  expect_equals "".hash_code foo
