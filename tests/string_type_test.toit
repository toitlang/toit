// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

foo str/string -> string:
  return str + "x"

glob/string ::= "pre"

main:
  expect_equals "prex" (foo glob)
