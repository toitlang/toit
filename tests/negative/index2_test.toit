// Copyright (C) 2019 Toitware ApS. All rights reserved.

main:
  x := []
  x[break break unresolved] = 3

  y := "foo $x[break break unresolved]"
  y = "foo $x[break break]"
