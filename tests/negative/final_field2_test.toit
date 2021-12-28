// Copyright (C) 2020 Toitware ApS. All rights reserved.

class A:
  field ::= null

confuse x: return x
main:
  a := A
  (confuse a).field = 499
