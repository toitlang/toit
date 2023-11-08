// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import system
import system show platform

main:
  if platform != system.PLATFORM-FREERTOS:
    test-huge

test-huge:
  list := []
  BIG := 1_000_000
  set-random-seed "Toitness of Toit"
  BIG.repeat:
    list.add "$(random BIG)"
  sum := 0
  1_000.repeat:
    sum += list[random BIG].size
  expect-equals 5894 sum
