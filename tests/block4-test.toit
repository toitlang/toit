// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  b := (: print it)
  run-loop := true
  b2 := while run-loop:
    run-loop = false
    b
  expect-null b2
  
  b2 = for i := 0; i < 1; i++:
    b
  expect-null b2
