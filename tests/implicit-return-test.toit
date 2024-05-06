// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  expect-null implicit-return
  expect-null implicit-return-42
  expect-null implicit-return-42-s
  expect-null implicit-return-42-43
  expect-null implicit-return-42-43-s

  c := C
  expect-null c.implicit-return
  expect-null c.implicit-return-42
  expect-null c.implicit-return-42-s
  expect-null c.implicit-return-42-43
  expect-null c.implicit-return-42-43-s

  expect-equals
    42
    exec: 42
  expect-equals
    42
    exec: 42;
  expect-equals
    43
    exec: 42; 43
  expect-equals
    43
    exec: 42; 43;

implicit-return:
implicit-return-42:
  42
implicit-return-42-s:
  42;
implicit-return-42-43:
  42; 43
implicit-return-42-43-s:
  42; 43;

class C:
  implicit-return:
  implicit-return-42:
    42
  implicit-return-42-s:
    42;
  implicit-return-42-43:
    42; 43
  implicit-return-42-43-s:
    42; 43;

exec [block]:
  return block.call
