// Copyright (C) 2020 Toitware ApS. All rights reserved.

import expect show *

foo x="":
  #primitive.core.string_hash_code

main:
  expect_equals "str".hash_code (foo "str")
  expect_equals "".hash_code foo
