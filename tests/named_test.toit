// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

// Add test, that literal-list and literal-set lead to
// temoraries:

side_sum := 0
side_multiplier := 1

class A:
  foo --x --y --z:
    side_sum += 1 * side_multiplier


create_a:
  side_sum += 1000 * side_multiplier++
  return A

side x:
  side_sum += x * 10 * side_multiplier++
  return x

main:
  create_a.foo --z={ 499: (side 3)} --y=[(side 1)] --x={(side 2)}
  expect_equals (1*1000 + 2*3*10 + 3*1*10 + 4*2*10 + 1*5) side_sum
