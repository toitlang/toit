// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  expect (recursive_fib 1) == 1  --message="recursive fib #0"
  expect (recursive_fib 2) == 1  --message="recursive fib #1"
  expect (recursive_fib 5) == 5  --message="recursive fib #2"
  expect (recursive_fib 8) == 21 --message="recursive fib #3"

  expect (iterative_fib 1) == 1  --message="iterative fib #0"
  expect (iterative_fib 2) == 1  --message="iterative fib #1"
  expect (iterative_fib 5) == 5  --message="iterative fib #2"
  expect (iterative_fib 8) == 21 --message="iterative fib #3"

recursive_fib n:
  if n <= 2: return 1
  return (recursive_fib n - 1) + (recursive_fib n - 2)

iterative_fib n:
  if n <= 2: return 1

  n1 := 1
  n2 := 1
  i := 3

  while i < n:
    tmp := n2
    n2 = n2 + n1
    n1 = tmp
    i++
  return n1 + n2
