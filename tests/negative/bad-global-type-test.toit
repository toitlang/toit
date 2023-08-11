// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

global /int := 499
global2 := 42
global3 := global4 + global4
global4 := global3 + global3
global5 := global5 + 1

main:
  global2 = "str"
  unresolved
