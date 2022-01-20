// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  if platform != "FreeRTOS":
    test_huge

test_huge:
  list := []
  BIG := 1_000_000
  set_random_seed "Toitness of Toit"
  BIG.repeat:
    list.add "$(random BIG)"
  sum := 0
  1_000.repeat:
    sum += list[random BIG].size
  expect_equals 5894 sum
