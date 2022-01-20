// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

expect_ name [code]:
  expect_equals
    name
    catch code

expect_allocation_failed [code]:
  expect_ "ALLOCATION_FAILED" code

main:
  set_max_heap_size_ 30000
  expect_allocation_failed:
    a := []
    while true:
      s := "Abcdefghijklmnopqrstuvwxyz $a.size"
      8.repeat: s += s
      a.add s.size
      if (a.size % 100) == 0: print a.size
