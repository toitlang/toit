// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.
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
