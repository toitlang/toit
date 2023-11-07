// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  i := 0
  for loop-var ::= ?; i < 2; i++:
    loop-var = 42
    expect-equals 42 loop-var
