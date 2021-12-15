// Copyright (C) 2021 Toitware ApS. All rights reserved.

import expect show *

main:
  test_deque

test_deque:
  deque := Deque
  deque.add_all [13, 1, 13, 13, 2]
  deque.add 13
  expect deque.size == 6

  expect (deque.any: it == 2)
  expect (deque.every: it != 7)
  expect (deque.contains 1)
  expect (deque.contains 13)
  expect (not deque.contains 7)

  expect_equals 13 deque.first
  expect_equals 13 deque.remove_first
  expect deque.size == 5

  expect_equals 1 deque.first
  expect_equals 1 deque.remove_first
  expect deque.size == 4

  expect (not deque.contains 1)

  expect_equals 13 * 13 * 13 * 2
    deque.reduce: | a b | a * b

  expect_equals 13 + 13 + 13 + 2
    deque.reduce: | a b | a + b

  expect_equals 0
    deque.reduce --initial=0: | a b | a * b

  // clear
  deque.clear
  expect_equals 0 deque.size
  // add_all
  deque.add_all [1, 2]
  expect_equals 2 deque.size
  // remove_last
  expect_equals 2 deque.last
  expect_equals 2 deque.remove_last
  expect_equals 1 deque.size
  // remove_last
  expect_equals 1 deque.last
  expect_equals 1 deque.remove_last
  expect_equals 0 deque.size

  deque.add 42
  deque.add 103

  // Keep removing first.
  100_000.repeat:
    deque.add it
    removed := deque.remove_first
    if it > 1:
      expect_equals it - 2 removed

  expect_equals 99_998 deque.first
  expect_equals 99_999 deque.last

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
