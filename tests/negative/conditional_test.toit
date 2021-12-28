// Copyright (C) 2019 Toitware ApS. All rights reserved.

foo x:
main:
  x := foo ? unresolved
  y := foo ? foo
  unresolved
  z := foo ? foo :
  unresolved
