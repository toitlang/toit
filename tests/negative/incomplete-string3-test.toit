// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

foo x/int:

main:
  z := 499
  foo "str"
  y := """
    $z
  unresolved
