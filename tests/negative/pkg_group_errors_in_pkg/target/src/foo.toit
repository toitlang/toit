// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

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
