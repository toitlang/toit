// Copyright (C) 2018 Toitware ApS. All rights reserved.

import expect show *

foo str/string -> string:
  return str + "x"

glob/string ::= "pre"

main:
  expect_equals "prex" (foo glob)
