// Copyright (C) 2019 Toitware ApS. All rights reserved.

import .invoke_var_test as pre

global := 499

class A:
  static static_field := 499

main:
  local := 499
  local 1
  global 2
  pre 3
  pre.global 4
  A.static_field 5
  pre.A.static_field 6
