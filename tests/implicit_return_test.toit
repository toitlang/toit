// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  expect_null implicit_return
  expect_null implicit_return_42
  expect_null implicit_return_42_s
  expect_null implicit_return_42_43
  expect_null implicit_return_42_43_s

  c := C
  expect_null c.implicit_return
  expect_null c.implicit_return_42
  expect_null c.implicit_return_42_s
  expect_null c.implicit_return_42_43
  expect_null c.implicit_return_42_43_s

  expect_equals
    42
    exec: 42
  expect_equals
    42
    exec: 42;
  expect_equals
    43
    exec: 42; 43
  expect_equals
    43
    exec: 42; 43;

implicit_return:
implicit_return_42:
  42
implicit_return_42_s:
  42;
implicit_return_42_43:
  42; 43
implicit_return_42_43_s:
  42; 43;

class C:
  implicit_return:
  implicit_return_42:
    42
  implicit_return_42_s:
    42;
  implicit_return_42_43:
    42; 43
  implicit_return_42_43_s:
    42; 43;

exec [block]:
  return block.call
