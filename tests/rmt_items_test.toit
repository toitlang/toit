// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import rmt show Items

main:
  test_items_construction
  test_items_getters
  test_items_setter
  test_items_do

test_items_construction:
  items := Items 4
  expect_equals 4 items.size
  expect_equals 8 items.bytes.size

  items = Items 5
  expect_equals 5 items.size
  expect_equals 12 items.bytes.size

  bytes := #[0x11, 0x22, 0x33, 0x44]
  items = Items.from_bytes bytes
  expect_equals 2 items.size
  expect_bytes_equal bytes items.bytes

  bytes = #[0x11, 0x22, 0x33, 0x44, 0x55]
  expect_throw "INVALID_ARGUMENT":
    Items.from_bytes bytes

test_items_getters:


test_items_setter:


test_items_do:
