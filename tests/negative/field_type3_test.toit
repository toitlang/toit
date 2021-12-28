// Copyright (C) 2020 Toitware ApS. All rights reserved.

class A:
  x / string := ?
  constructor .x:

confuse x: return x

main:
  A (confuse null)
