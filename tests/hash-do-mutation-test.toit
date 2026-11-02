// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

// Changing a set or a map while iterating over it isn't supported, but it must
// not throw or crash. Both the interpreter and native code stop at the end of
// what is left of the backing.

test-set:
  set := {}
  100.repeat: set.add it
  seen := 0
  set.do:
    seen++
    if it == 3:
      90.repeat: | i | set.remove i + 10
  expect-equals 10 seen

test-map:
  map := {:}
  100.repeat: map[it] = it * 2
  seen := 0
  map.do: | key value |
    seen++
    expect-equals key * 2 value
    if key == 3:
      90.repeat: | i | map.remove i + 10
  expect-equals 10 seen

test-keys-only:
  map := {:}
  10.repeat: map[it] = it
  sum := 0
  map.do --keys: sum += it
  expect-equals 45 sum

test-zero-values:
  // A zero that is stored or found must not be mistaken for a missing value.
  map := {0: 0, 1: 0}
  count := 0
  map.do: | key value |
    expect-equals 0 value
    count++
  expect-equals 2 count
  list := [0, 0, 0]
  list[1] = 0
  expect-equals 0 list[1]
  expect-equals 3 list.size

main:
  test-zero-values
  test-set
  test-map
  test-keys-only
