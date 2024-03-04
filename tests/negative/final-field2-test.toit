// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ..confuse

class A:
  field ::= null

main:
  a := A
  (confuse a).field = 499
