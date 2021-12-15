// Copyright (C) 2018 Toitware ApS. All rights reserved.

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
