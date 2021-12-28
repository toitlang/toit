// Copyright (C) 2020 Toitware ApS. All rights reserved.
// TEST_FLAGS: --force

class A:
  field ::= null

main:
  a := A
  a.field = 499
