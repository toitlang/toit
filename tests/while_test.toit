// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  test_simple_break
  test_complex_break
  test_continue
  test_while_as_expression
  test_while_definition

test_simple_break:
  while true:
    if true: break

test_complex_break:
  i := 0
  while true:
    i++
    if i > 5: break
  expect i == 6

test_continue:
  i := 0
  while i < 5:
    i++
    if true: continue
  expect_equals 5 i

  count := 0
  i = 0
  while i < 5:
    i++
    if i % 2 == 1: continue
    count++
  expect_equals 5 i
  expect_equals 2 count

test_while_as_expression:
  i := 0
  n := 0

  n = 87
  n = exec:
    while false: 41; 42
  expect_null n

  n = 87
  n = exec:
    while false: 41; 42;
  expect_null n

  i = 0
  n = 87
  n = exec:
    while i < 1: i = i + 1
  expect_null n

  i = 0
  n = 87
  n = exec:
    while i < 1: i = i + 1; 42
  expect_null n

  i = 0
  n = 87
  n = exec:
    while i < 1: i = i + 1; 42;
  expect_null n

up_to_ten x:
  return x < 10 ? x : null

test_while_definition:
  count := 0
  sum := 0

  while foo := up_to_ten count++:
    sum += foo

  expect_equals 45 sum

  count = 0
  sum = 0

  while foo ::= up_to_ten count++:
    sum += foo

  expect_equals 45 sum

even_null_odd_false_up_to_ten x/int:
  if x >= 10: return true
  if x % 2 == 0: return null
  return false

exec [block]:
  return block.call
