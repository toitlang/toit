// Copyright (C) 2020 Toitware ApS. All rights reserved.

some_fun x: return x

use x:

main:
  i := 0
  for local ::= ?; i < 3; local = 499:
    local = 42
    i++

  while local ::= ?:
    local = 42
    local = 499

  while local ::= ?:
    while false:
      local = 499

  unresolved
