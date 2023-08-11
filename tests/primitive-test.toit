// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

foo x="":
  #primitive.core.string-hash-code

main:
  expect-equals "str".hash-code (foo "str")
  expect-equals "".hash-code foo
