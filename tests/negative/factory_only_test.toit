// Copyright (C) 2018 Toitware ApS. All rights reserved.

class A:
  constructor:
    return confuse null

confuse x -> any: return x

main:
  a := A
