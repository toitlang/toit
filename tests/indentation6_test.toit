// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

class L:
  sorted [b]:
    return b.call 2 1

do x:
  return x

something ::= "ok"

run [b]:
  return b.call

main:
  x := run:
    if
      (L).sorted: |a b| a > b:
      do something
  expect_equals "ok" x
