// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

LITERAL1 ::= "foo"
LITERAL2 ::= "bar"

main:
  expect-not-null (literal-index_ LITERAL1)
  expect-not-null (literal-index_ LITERAL2)
  expect-null (literal-index_ Time.now.stringify)
