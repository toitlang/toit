// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  test-for-as-expression
  expect-null test-declaration-in-for
  expect-equals 0 test-regression
  test-break
  test-continue
  test-empty-init-cond-update

test-for-as-expression:
  i := 0
  n := 0

  n = 87
  n = exec: for 0; false; 0: 41; 42
  expect-null n

  n = 87
  n = exec: for 0; false; 0: 41; 42;
  expect-null n

  n = 87
  n = exec: for i = 0; i < 1; i++: // Do nothing.
  expect-null n

  n = 87
  n = exec: for i = 0; i < 1; 0: ++i
  expect-null n

  n = 87
  n = exec: for i = 0; i < 1; i++: 42
  expect-null n

  n = 87
  n = exec: for i = 0; i < 1; i++: 42;
  expect-null n

  n = 87
  n = exec: for j := 0; j < 1; j++: // Do nothing.
  expect-null n

  n = 87
  n = exec: for j := 0; j < 1; 0: ++j
  expect-null n

  n = 87
  n = exec: for j := 0; j < 1; j++: 42
  expect-null n

  n = 87
  n = exec: for j := 0; j < 1; j++: 42;
  expect-null n

exec [block]:
  return block.call

test-declaration-in-for:
  for i := 0; i < 0; i++: x := 0

test-regression:
  first := null
  s := 0
  for c := first; c != null; c = c.next: s++
  return s

test-break:
  for i := 0; i < 5; throw "bad":
    if true: break

  count := 0
  for i := 0; i < 10; i++:
    count++
    if i > 5: break
  expect-equals 7 count

test-continue:
  count := 0
  for i := 0; i < 5; i++:
    count++
    if true: continue
  expect-equals 5 count

  count = 0
  for i := 0; i < 5; i++:
    if true: continue
    count++
  expect-equals 0 count

  count = 0
  for i := 0; i < 5; i++:
    if i % 2 == 1: continue
    count++
  expect-equals 3 count

test-empty-init-cond-update:
  x := 0
  for ;;:
    x++
    if x == 5: break
  expect-equals 5 x

  x = 0
  for y := 0;;y++:
    x++
    if y == 3: break
  expect-equals 4 x

  x = 0
  for ; x < 3; x++:
  expect-equals 3 x
