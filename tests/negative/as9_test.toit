// Copyright (C) 2020 Toitware ApS. All rights reserved.

confuse x -> any: return x
class A:
main:
  a := A
  a = confuse null
  a as A
