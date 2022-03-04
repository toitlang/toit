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
  item := Item 0 1024
  expect_equals 0 item.value
  expect_equals 1024 item.period

  item = Item 1 0
  expect_equals 1 item.value
  expect_equals 0 item.period

test_item_construction_truncates_values:
  item := Item 2 0xFFFF
  expect_equals 0 item.value
  expect_equals 0x7FFF item.period

test_item_serialization:
  item := Item 0 0
  expect_bytes_equal
    #[0x00,0x00]
    #[item.first_byte, item.second_byte]

  item = Item 1 0
  expect_bytes_equal
    #[0x00,0x80]
    #[item.first_byte, item.second_byte]

  item = Item 0 0x7FFF
  expect_bytes_equal
    #[0xFF,0x7F]
    #[item.first_byte, item.second_byte]

  item = Item 1 0x7FFF
  expect_bytes_equal
    #[0xFF,0xFF]
    #[item.first_byte, item.second_byte]

  item = Item 0 0x700F
  expect_bytes_equal
    #[0x0F,0x70]
    #[item.first_byte, item.second_byte]

  item = Item 1 0x700F
  expect_bytes_equal
    #[0x0F,0xF0]
    #[item.first_byte, item.second_byte]

  item = Item 0 1024
  expect_equals
    item
    Item.from_bytes 0
      ByteArray 2: it == 0 ? item.first_byte : item.second_byte
