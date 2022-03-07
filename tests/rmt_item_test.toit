// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import rmt show Item

main:
  test_item_construction
  test_item_construction_truncates_values
  test_item_serialization

test_item_construction:
  item := Item 1024 0
  expect_equals 0 item.value
  expect_equals 1024 item.period

  item = Item 0 1
  expect_equals 1 item.value
  expect_equals 0 item.period

test_item_construction_truncates_values:
  item := Item 0xFFFF 2
  expect_equals 0 item.value
  expect_equals 0x7FFF item.period

test_item_serialization:
  item := Item 0 0
  expect_bytes_equal
    #[0x00,0x00]
    #[item.first_byte_, item.second_byte_]

  item = Item 0 1
  expect_bytes_equal
    #[0x00,0x80]
    #[item.first_byte_, item.second_byte_]

  item = Item 0x7FFF 0
  expect_bytes_equal
    #[0xFF,0x7F]
    #[item.first_byte_, item.second_byte_]

  item = Item 0x7FFF 1
  expect_bytes_equal
    #[0xFF,0xFF]
    #[item.first_byte_, item.second_byte_]

  item = Item 0x700F 0
  expect_bytes_equal
    #[0x0F,0x70]
    #[item.first_byte_, item.second_byte_]

  item = Item 0x700F 1
  expect_bytes_equal
    #[0x0F,0xF0]
    #[item.first_byte_, item.second_byte_]

  item = Item 1024 0
  expect_equals
    item
    Item.from_bytes 0
      ByteArray 2: it == 0 ? item.first_byte_ : item.second_byte_

  item = Item 0 1
  expect_equals
    item
    Item.from_bytes 0
      ByteArray 2: it == 0 ? item.first_byte_ : item.second_byte_
