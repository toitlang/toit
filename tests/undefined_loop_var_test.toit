// Copyright (C) 2020 Toitware ApS. All rights reserved.

import expect show *

main:
  i := 0
  for loop_var ::= ?; i < 2; i++:
    loop_var = 42
    expect_equals 42 loop_var
