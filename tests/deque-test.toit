// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  test-deque
  test-at Deque
  test-at List
  test-copy

test-deque:
  deque := Deque
  deque.add-all [13, 1, 13, 13, 2]
  deque.add 13
  expect deque.size == 6

  expect (deque.any: it == 2)
  expect (deque.every: it != 7)
  expect (deque.contains 1)
  expect (deque.contains 13)
  expect (not deque.contains 7)

  expect-equals 13 deque.first
  expect-equals 13 deque.remove-first
  expect deque.size == 5

  deque.add-first 55
  expect-equals 55 deque.first
  deque.add-first 103
  expect-equals 103 deque.first
  expect-equals 103 deque.remove-first
  expect-equals 55 deque.remove-first

  expect-equals 1 deque.first
  expect-equals 1 deque.remove-first
  expect deque.size == 4

  expect (not deque.contains 1)

  expect-equals 13 * 13 * 13 * 2
    deque.reduce: | a b | a * b

  expect-equals 13 + 13 + 13 + 2
    deque.reduce: | a b | a + b

  expect-equals 0
    deque.reduce --initial=0: | a b | a * b

  // clear
  deque.clear
  expect-equals 0 deque.size
  // add_all
  deque.add-all [1, 2]
  expect-equals 2 deque.size
  // remove_last
  expect-equals 2 deque.last
  expect-equals 2 deque.remove-last
  expect-equals 1 deque.size
  // remove_last
  expect-equals 1 deque.last
  expect-equals 1 deque.remove-last
  expect-equals 0 deque.size

  deque.add 42
  deque.add 103

  // Keep removing first.
  100_000.repeat:
    deque.add it
    removed := deque.remove-first
    if it > 1:
      expect-equals it - 2 removed

  expect-equals 99_998 deque.first
  expect-equals 99_999 deque.last

  first := true

  deque.do:
    if first:
      expect it == 99_998
      first = false
    else:
      expect it == 99_999

  first = true

  deque.do --reversed:
    if first:
      expect it == 99_999
      first = false
    else:
      expect it == 99_998

test-at list:
  expect-equals 0 list.size
  expect-equals "[]" list.stringify
  expect-throw "OUT_OF_BOUNDS": list[0]
  expect-throw "OUT_OF_BOUNDS": list.remove-last
  expect-throw "OUT_OF_BOUNDS": list.remove --at=0
  expect-throw "OUT_OF_BOUNDS": list.remove --at=-1
  expect-throw "OUT_OF_BOUNDS": list.remove --at=1
  expect-throw "OUT_OF_BOUNDS": list.insert --at=-1 "foo"
  expect-throw "OUT_OF_BOUNDS": list.insert --at=1 "foo"
  list.insert --at=0 "foo"
  expect-equals 1 list.size
  expect-equals "[foo]" list.stringify
  expect-throw "OUT_OF_BOUNDS": list.remove --at=-1
  expect-throw "OUT_OF_BOUNDS": list.remove --at=1
  expect-throw "OUT_OF_BOUNDS": list.insert --at=-1 "bar"
  expect-throw "OUT_OF_BOUNDS": list.insert --at=2 "bar"
  expect-equals "foo" (list.remove --at=0)
  expect-equals 0 list.size
  expect-equals "[]" list.stringify
  list.insert --at=0 "foo"
  list.insert --at=0 "bar"
  expect-equals "[bar, foo]" list.stringify
  list.insert --at=2 "baz"
  expect-equals 3 list.size
  expect-equals "[bar, foo, baz]" list.stringify
  expect-equals "foo" (list.remove --at=1)
  expect-equals "[bar, baz]" list.stringify
  expect-equals "bar" (list.remove --at=0)
  expect-equals "[baz]" list.stringify
  expect-equals 1 list.size
  expect-equals "baz" (list.remove --at=0)

  10.repeat: list.add it
  expect-equals "[0, 1, 2, 3, 4, 5, 6, 7, 8, 9]" list.stringify
  expect-equals 7 (list.remove --at=7)
  expect-equals "[0, 1, 2, 3, 4, 5, 6, 8, 9]" list.stringify
  expect-equals 1 (list.remove --at=1)
  expect-equals "[0, 2, 3, 4, 5, 6, 8, 9]" list.stringify
  expect-equals 3 (list.remove --at=2)
  expect-equals "[0, 2, 4, 5, 6, 8, 9]" list.stringify
  expect-equals 6 (list.remove --at=4)
  expect-equals "[0, 2, 4, 5, 8, 9]" list.stringify
  expect-equals 2 (list.remove --at=1)
  expect-equals "[0, 4, 5, 8, 9]" list.stringify
  expect-equals 8 (list.remove --at=3)
  expect-equals "[0, 4, 5, 9]" list.stringify
  expect-equals 4 (list.remove --at=1)
  expect-equals "[0, 5, 9]" list.stringify
  expect-equals 5 (list.remove --at=1)
  expect-equals "[0, 9]" list.stringify
  expect-equals 9 (list.remove --at=1)
  expect-equals "[0]" list.stringify
  expect-equals 0 (list.remove --at=0)
  expect-equals "[]" list.stringify

  10.repeat: list.insert --at=list.size it
  expect-equals 10 list.size
  expect-equals "[0, 1, 2, 3, 4, 5, 6, 7, 8, 9]" list.stringify
  list.insert --at=1 42
  expect-equals 11 list.size
  expect-equals "[0, 42, 1, 2, 3, 4, 5, 6, 7, 8, 9]" list.stringify
  list.insert --at=9 103
  expect-equals "[0, 42, 1, 2, 3, 4, 5, 6, 7, 103, 8, 9]" list.stringify
  list.insert --at=8 102
  expect-equals "[0, 42, 1, 2, 3, 4, 5, 6, 102, 7, 103, 8, 9]" list.stringify
  list.insert --at=(list.size - 1) 99
  expect-equals "[0, 42, 1, 2, 3, 4, 5, 6, 102, 7, 103, 8, 99, 9]" list.stringify
  list.insert --at=2 -1
  expect-equals "[0, 42, -1, 1, 2, 3, 4, 5, 6, 102, 7, 103, 8, 99, 9]" list.stringify

  expect-equals 0 (list.index-of 0)
  expect-equals 1 (list.index-of 42)
  list.clear
  expect-equals 0 list.size
  10.repeat: list.add it
  expect-equals "[0, 1, 2, 3, 4, 5, 6, 7, 8, 9]" list.stringify
  expect-equals 5 (list.index-of --binary 5)
  r := list.index-of --binary 10 --if-absent=:
    expect-equals 10 it
    42
  expect-equals 42 r
  r = list.index-of --binary -1 --if-absent=:
    expect-equals 0 it
    42
  expect-equals 42 r
  expect-equals 0 (list.remove --at=0)
  expect-equals 1 (list.remove --at=0)
  r = list.index-of --binary 10 --if-absent=:
    expect-equals 8 it
    42
  expect-equals 42 r
  expect-equals "[2, 3, 4, 5, 6, 7, 8, 9]" list.stringify
  r = list.index-of --binary 8 0 5 --if-absent=:
    expect-equals 5 it
    42
  expect-equals 42 r
  expect-equals "[2, 3, 4, 5, 6, 7, 8, 9]" list.stringify
  r = list.index-of --binary 8 0 6 --if-absent=:
    expect-equals 6 it
    42
  expect-equals 42 r
  expect-equals 6 (list.index-of --binary 8 0 7)
  expect-equals 42 r

test-copy:
  d := Deque
  d.add-all [1, 2, 3]
  d2/Deque := d.copy
  d[1] = 42
  d2[1] = 103
  expect-equals "[1, 42, 3]" d.stringify
  expect-equals "[1, 103, 3]" d2.stringify
  d.remove-last
  d2.remove-first
  expect-equals "[1, 42]" d.stringify
  expect-equals "[103, 3]" d2.stringify
