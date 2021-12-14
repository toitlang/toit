// Copyright (C) 2021 Toitware ApS. All rights reserved.

import expect show *

LITERAL1 ::= "foo"
LITERAL2 ::= "bar"

main:
  expect_not_null (literal_index_ LITERAL1)
  expect_not_null (literal_index_ LITERAL2)
  expect_null (literal_index_ Time.now.stringify)
