// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  test-simple-break
  test-complex-break
  test-continue
  test-while-as-expression
  test-while-definition

test-simple-break:
  while true:
    if true: break

test-complex-break:
  i := 0
  while true:
    i++
    if i > 5: break
  expect i == 6

test-continue:
  i := 0
  while i < 5:
    i++
    if true: continue
  expect-equals 5 i

  count := 0
  i = 0
  while i < 5:
    i++
    if i % 2 == 1: continue
    count++
  expect-equals 5 i
  expect-equals 2 count

test-while-as-expression:
  i := 0
  n := 0

  n = 87
  n = exec:
    while false: 41; 42
  expect-null n

  n = 87
  n = exec:
    while false: 41; 42;
  expect-null n

  i = 0
  n = 87
  n = exec:
    while i < 1: i = i + 1
  expect-null n

  i = 0
  n = 87
  n = exec:
    while i < 1: i = i + 1; 42
  expect-null n

  i = 0
  n = 87
  n = exec:
    while i < 1: i = i + 1; 42;
  expect-null n

up-to-ten x:
  return x < 10 ? x : null

test-while-definition:
  count := 0
  sum := 0

  while foo := up-to-ten count++:
    sum += foo

  expect-equals 45 sum

  count = 0
  sum = 0

  while foo ::= up-to-ten count++:
    sum += foo

  expect-equals 45 sum

even-null-odd-false-up-to-ten x/int:
  if x >= 10: return true
  if x % 2 == 0: return null
  return false

exec [block]:
  return block.call
