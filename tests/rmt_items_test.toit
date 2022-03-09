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
  bytes := #[
    0x00, 0x00,
    0xFF, 0xFF,
    0xFF, 0x7F,
    0x00, 0x80
    ]
  items := Items.from_bytes bytes
  expect_equals 0 (items.item_level 0)
  expect_equals 0 (items.item_period 0)
  
  expect_equals 1 (items.item_level 1)
  expect_equals 0x7FFF (items.item_period 1)

  expect_equals 0 (items.item_level 2)
  expect_equals 0x7FFF (items.item_period 2)

  expect_equals 1 (items.item_level 3)
  expect_equals 0 (items.item_period 3)

  expect_throw "OUT_OF_BOUNDS": items.item_level -1
  expect_throw "OUT_OF_BOUNDS": items.item_period -1
  expect_throw "OUT_OF_BOUNDS": items.item_level 4
  expect_throw "OUT_OF_BOUNDS": items.item_period 4

test_items_setter:
  items := Items 3
  items.do: | period level |
    expect_equals 0 period
    expect_equals 0 level
  
  items.set_item 0 8 1
  expect_equals 8 
    items.item_period 0
  expect_equals 1
    items.item_level 0

  items.set_item 1 0x7FFF 0
  expect_equals 0x7FFF
    items.item_period 1
  expect_equals 0
    items.item_level 1

  items.set_item 2 0 1
  expect_equals 0
    items.item_period 2
  expect_equals 1
    items.item_level 0

test_items_do:
  bytes := #[
    0x00, 0x00,
    0x01, 0x00,
    0x02, 0x00,
    0x03, 0x00
    ]
  items := Items.from_bytes bytes
  item_count := 0
  items.do: | period level |
    expect_equals item_count period
    expect_equals 0 level
    item_count++
  expect_equals 4 item_count

  items = Items 3
  item_count = 0
  items.do: item_count++
  expect_equals 3 item_count
