// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  test_for_as_expression
  expect_null test_declaration_in_for
  expect_equals 0 test_regression
  test_break
  test_continue
  test_empty_init_cond_update

test_for_as_expression:
  i := 0
  n := 0

  n = 87
  n = exec: for 0; false; 0: 41; 42
  expect_null n

  n = 87
  n = exec: for 0; false; 0: 41; 42;
  expect_null n

  n = 87
  n = exec: for i = 0; i < 1; i++: // Do nothing.
  expect_null n

  n = 87
  n = exec: for i = 0; i < 1; 0: ++i
  expect_null n

  n = 87
  n = exec: for i = 0; i < 1; i++: 42
  expect_null n

  n = 87
  n = exec: for i = 0; i < 1; i++: 42;
  expect_null n

  n = 87
  n = exec: for j := 0; j < 1; j++: // Do nothing.
  expect_null n

  n = 87
  n = exec: for j := 0; j < 1; 0: ++j
  expect_null n

  n = 87
  n = exec: for j := 0; j < 1; j++: 42
  expect_null n

  n = 87
  n = exec: for j := 0; j < 1; j++: 42;
  expect_null n

exec [block]:
  return block.call

test_declaration_in_for:
  for i := 0; i < 0; i++: x := 0

test_regression:
  first := null
  s := 0
  for c := first; c != null; c = c.next: s++
  return s

test_break:
  for i := 0; i < 5; throw "bad":
    if true: break

  count := 0
  for i := 0; i < 10; i++:
    count++
    if i > 5: break
  expect_equals 7 count

test_continue:
  count := 0
  for i := 0; i < 5; i++:
    count++
    if true: continue
  expect_equals 5 count

  count = 0
  for i := 0; i < 5; i++:
    if true: continue
    count++
  expect_equals 0 count

  count = 0
  for i := 0; i < 5; i++:
    if i % 2 == 1: continue
    count++
  expect_equals 3 count

test_empty_init_cond_update:
  x := 0
  for ;;:
    x++
    if x == 5: break
  expect_equals 5 x

  x = 0
  for y := 0;;y++:
    x++
    if y == 3: break
  expect_equals 4 x

  x = 0
  for ; x < 3; x++:
  expect_equals 3 x
