// Copyright (C) 2020 Toitware ApS. All rights reserved.

import expect show *

call_fun fun: fun.call

test1 arg:
  if arg:
    return 499
  else:
    return 42

test2 arg:
  if arg:
    return 499
  else:
    throw "bad"

test3 arg:
  if not arg:
    throw "bad"
  else:
    return 499

test4:
  for i := 0; i < 0; i++:
    throw "bad"
  return 499

test5:
  while (return 499):
    throw "bad"

test6:
  (return 499) or (throw "bad")

test7:
  (return 499) and (throw "bad")

test8:
  try:
    return 499
  finally:

test9 -> int:
  try:
    throw "caught"
  finally:

monitor Mon:
  test1 arg:
    if arg:
      return 499
    else:
      return 42

  test2 arg:
    if arg:
      return 499
    else:
      throw "bad"

  test3 x -> any:
    call_fun:: x++
    return x

// Test, that return followed by a delimiter works.
testA x:
  if x == 1:
    return;
  else if x == 2:
    (return)

main:
  expect_equals 499 (test1 true)
  expect_equals 499 (test2 true)
  expect_equals 499 (test3 true)
  expect_equals 499 test4
  expect_equals 499 test5
  expect_equals 499 test6
  expect_equals 499 test7
  expect_equals 499 test8
  expect_equals "caught" (catch: test9)
  expect_equals 499 ((Mon).test1 true)
  expect_equals 499 ((Mon).test2 true)
  expect_equals 499 ((Mon).test3 498)
  testA 1
