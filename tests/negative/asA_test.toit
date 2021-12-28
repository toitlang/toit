// Copyright (C) 2020 Toitware ApS. All rights reserved.

confuse x -> any: return x

interface I:
class A implements I:

main:
  a := A
  a = confuse null
  a as I
