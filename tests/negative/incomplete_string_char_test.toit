// Copyright (C) 2019 Toitware ApS. All rights reserved.

foo x/int:

main:
  z := 499
  x := "foo
  x = "$z foo
  x = "$(z) foo
  x = "$(%_ 499)"
  unresolved
  foo "str"
  y := """
  unresolved
