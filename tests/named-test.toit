// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

// Add test, that literal-list and literal-set lead to
// temoraries:

side-sum := 0
side-multiplier := 1

class A:
  foo --x --y --z:
    side-sum += 1 * side-multiplier


create-a:
  side-sum += 1000 * side-multiplier++
  return A

side x:
  side-sum += x * 10 * side-multiplier++
  return x

main:
  create-a.foo --z={ 499: (side 3)} --y=[(side 1)] --x={(side 2)}
  expect-equals (1*1000 + 2*3*10 + 3*1*10 + 4*2*10 + 1*5) side-sum
