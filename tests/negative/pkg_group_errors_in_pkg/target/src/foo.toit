// Copyright (C) 2021 Toitware ApS. All rights reserved.

import .bar
import .gee

interface I1:
  foo -> string
  bar x y

class B implements I1:

class C:
  foo x:
  foo x y=499:
  foo x y=43 z=23:

toto:
  ambiguous
