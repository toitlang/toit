// Copyright (C) 2019 Toitware ApS. All rights reserved.

main:
  block := (: true)
  while x := block:
    print x
  y := 0
  for x := block; x.call; y++:
    print x

  fun := null
  while x := block:
    fun = :: x

  y = 0
  for x := block; x.call; y++:
    fun = :: x
