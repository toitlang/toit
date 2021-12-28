// Copyright (C) 2019 Toitware ApS. All rights reserved.
import .ambiguous_a
import .ambiguous_b
import .ambiguous_a as prefix

C1 := 0

foo x/C1: null
bar x/AmbiguousC: null
gee x/prefix: null

foobar x/super: null

main:
  foo null
  bar null
  gee null
  foobar null
