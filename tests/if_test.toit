// Copyright (C) 2018 Toitware ApS. All rights reserved.

import expect show *

main:
  test_if
  test_else_if
  test_nested_if
  test_if_as_expression
  test_and
  test_or

test_if:
  n := 0

  n = 87
  if true: n = 42
  expect n == 42 --message="if #0"

  n = 87
  if false: n = 42
  expect n == 87 --message="if #1"

  n = 87
  if true: n = 42
  else: n = 43
  expect n == 42 --message="if #2"

  n = 87
  if false: n = 42
  else: n = 43
  expect n == 43 --message="if #3"

  n = 87
  if n: n = 42
  else: n = 43
  expect n == 42 --message="if #2"

  n = 87
  if null: n = 42
  else: n = 43
  expect n == 43 --message="if #3"

  x := if true: 42
  expect_equals 42 x
  x = if false: 42
  expect_null x

  n = 87
  if false:
    n = 42

  else:
    n = 99
  expect_equals 99 n

  n = 87
  x = if true: if false: n = 1
  else: n = 2
  expect_equals 87 n

test_else_if:
  n := 0
  if false:
    n = 42
  else if true:
    n = 87
  else:
    n = 99
  expect n == 87

  n == 0
  if false:
    n = 42
  else if false:
    n = 87
  else if true:
    n = 99
  expect n == 99

test_nested_if:
  n := 0
  if true:
    n = 1
    if false:
      n = 3
  else:
    n = 2
  expect_equals 1 n

  n = 0
  if true: n = 1; if false: n = 3
  else: n = 2
  expect_equals 1 n

test_if_as_expression:
  n := 0

  n = 87
  n = exec:
    if true: 41; 42
    else: 43; 44
  expect_equals 42 n

  n = 87
  n = exec:
    if false: 41; 42
    else: 43; 44
  expect_equals 44 n

  n = 87
  n = exec:
    if true: 41; 42;
    else: 43; 44;
  expect_equals 42 n

  n = 87
  n = exec:
    if false: 41; 42;
    else: 43; 44;
  expect_equals 44 n

exec [block]:
  return block.call

test_and:
  n0 := 0
  n1 := 0

  expect (true and true)
  expect (not (true and false))
  expect (not (false and true))
  expect (not (false and false))

  n0 = n1 = 0
  if true and (exec: n0 = 42) == 42: n1 = 87
  expect (n0 == 42 and n1 == 87)

  n0 = n1 = 0
  if true and (exec: n0 = 42) == 42: n1 = 87
  else: n1 = 99
  expect (n0 == 42 and n1 == 87)

  n0 = n1 = 0
  if true and (exec: n0 = 42) == 43: n1 = 87
  expect (n0 == 42 and n1 == 0)

  n0 = n1 = 0
  if true and (exec: n0 = 42) == 43: n1 = 87
  else: n1 = 99
  expect (n0 == 42 and n1 == 99)

  n0 = n1 = 0
  if 87 and (exec: n0 = 42) == 43: n1 = 87
  else: n1 = 99
  expect (n0 == 42 and n1 == 99)

  n0 = n1 = 0
  if false and (exec: n0 = 42) == 42: n1 = 87
  expect (n0 == 0 and n1 == 0)

  n0 = n1 = 0
  if false and (exec: n0 = 42) == 42: n1 = 87
  else: n1 = 99
  expect (n0 == 0 and n1 == 99)

  n0 = n1 = 0
  if null and (exec: n0 = 42) == 42: n1 = 87
  expect (n0 == 0 and n1 == 0)

  n0 = n1 = 0
  if null and (exec: n0 = 42) == 42: n1 = 87
  else: n1 = 99
  expect (n0 == 0 and n1 == 99)

test_or:
  n0 := 0
  n1 := 0

  expect (true or true)
  expect (true or false)
  expect (false or true)
  expect (not (false or false))

  n0 = n1 = 0
  if false or (exec: n0 = 42) == 42: n1 = 87
  expect (n0 == 42 and n1 == 87)

  n0 = n1 = 0
  if false or (exec: n0 = 42) == 42: n1 = 87
  else: n1 = 99
  expect (n0 == 42 and n1 == 87)

  n0 = n1 = 0
  if false or (exec: n0 = 42) == 43: n1 = 87
  expect (n0 == 42 and n1 == 0)

  n0 = n1 = 0
  if false or (exec: n0 = 42) == 43: n1 = 87
  else: n1 = 99
  expect (n0 == 42 and n1 == 99)

  n0 = n1 = 0
  if true or (exec: n0 = 42) == 42: n1 = 87
  expect (n0 == 0 and n1 == 87)

  n0 = n1 = 0
  if true or (exec: n0 = 42) == 42: n1 = 87
  else: n1 = 99
  expect (n0 == 0 and n1 == 87)
