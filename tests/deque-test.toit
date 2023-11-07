// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  test-deque

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
