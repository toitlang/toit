// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

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
