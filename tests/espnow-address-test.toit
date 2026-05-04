// Copyright (C) 2025 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import esp32.espnow

ADDRESS-STRING ::= "01:02:03:04:05:06"
main:

  address := espnow.Address.parse ADDRESS-STRING
  expect-equals ADDRESS-STRING address.to-string

  expect-throw "INVALID_ARGUMENT": espnow.Address.parse "01:02:03:04:05"
  expect-throw "INTEGER_PARSING_ERROR": espnow.Address.parse "01:02:03:04:05:ZZ"
  expect-throw "INVALID_ARGUMENT": espnow.Address.parse "01:02:03:04:05:06:07"
  expect-throw "INVALID_ARGUMENT": espnow.Address.parse "01:02:03:"
  expect-throw "INVALID_ARGUMENT": espnow.Address.parse "010203040506"
  expect-throw "INVALID_ARGUMENT": espnow.Address.parse ""
  expect-throw "INVALID_ARGUMENT": espnow.Address.parse "foo"

  address2 := espnow.Address #[1, 2, 3, 4, 5, 6]
  expect-equals address address2
  expect-equals address.hash-code address2.hash-code

  address3 := espnow.Address.parse "0a:0b:0c:0d:0e:0f"
  expect-not-equals address address3
  expect-equals #[0xa, 0xb, 0xc, 0xd, 0xe, 0xf] address3.mac

  address4 := espnow.Address.parse "0A:0B:0C:0D:0E:0F"
  expect-equals address3 address4
