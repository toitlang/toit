// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .non_existing as pre

class B:

main:
  a := A
  a is A
  a is 4
  a is pre.C
  a is none
  a is foo.bar

  a is
    not B

  a is (not B)
