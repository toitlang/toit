// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import bytes
import coap.tcp as coap
import coap.message as coap
import coap.option as coap
import expect show *
import reader show *

import .coap_client_test

expect_exception exception [code]:
  expect_equals
    exception
    catch code

main:
  test_parse_valid_message
  test_parse_invalid_message

  test_to_byte_array

parse data/ByteArray -> coap.TcpMessage?:
  return coap.TcpMessage.parse
    TestTransport
    BufferedReader
      bytes.Reader data

test_parse_valid_message:
  // Empty message.
  msg := parse #[0b00000000, 0]
  expect_equals 0 msg.code

  // Fields.
  msg = parse #[0b00000000, 0b010_01001]
  expect_equals 2 msg.code_class
  expect_equals 9 msg.code_detail

  // Options.
  msg = parse #[0b00100000, 0, 0b00110001, 0x42]
  expect_equals 1 msg.options.size
  expect_equals 3 msg.options[0].number
  expect_bytes_equal #[0x42] msg.options[0].value

  msg = parse #[0b01110000, 0, 0b00010000, 0b00100000, 0b11100000, 3, 1, 0b11010000, 5]
  expect_equals 4 msg.options.size
  expect_equals 1 msg.options[0].number
  expect_equals 3 msg.options[1].number
  expect_equals 1041 msg.options[2].number
  expect_equals 1059 msg.options[3].number

  // Payload.
  msg = parse #[0b00100000, 0, 0xff, 0x42]
  expect_bytes_equal #[0x42] msg.read_payload

  msg = parse #[0b01000000, 0, 0b00110001, 0x42, 0xff, 0x42]
  expect_equals 1 msg.options.size
  expect_bytes_equal #[0x42] msg.read_payload

  // Token.
  msg = parse #[0b00000100, 0, 0x42, 0x43, 0x44, 0x45]
  expect_equals
    coap.Token #[0x42, 0x43, 0x44, 0x45]
    msg.token

  // End of stream.
  expect_null
    parse #[]

test_parse_invalid_message:
  // Bad TKL.
  expect_exception "FORMAT_ERROR":
    parse #[0b00001111, 0]
  expect_exception "UNEXPECTED_END_OF_READER":
    parse #[0b00000111, 0]

  // Bad option.
  expect_exception "FORMAT_ERROR":
    parse #[0b00010000, 0, 0b11110000]
  expect_exception "FORMAT_ERROR":
    parse #[0b00010000, 0, 0b00001111]
  expect_exception "OUT_OF_RANGE":
    parse #[0b00010000, 0, 0b11010000]
  expect_exception "OUT_OF_RANGE":
    parse #[0b00010000, 0, 0b11100000]
  expect_exception "OUT_OF_RANGE":
    parse #[0b00010000, 0, 0b00000001]

test_to_byte_array:
  msg := coap.TcpMessage
  expect_bytes_equal #[0b00000000, 0] msg.header

  msg = coap.TcpMessage
  msg.code = coap.CODE_CONTENT
  expect_bytes_equal #[0b00000000, 0b01000101] msg.header

  msg = coap.TcpMessage
  msg.code = coap.CODE_GATEWAY_TIMEOUT
  expect_bytes_equal #[0b00000000, 0b10100100] msg.header

  // Token.
  msg = coap.TcpMessage
  msg.token = coap.Token
    ByteArray 3: it + 1
  expect_bytes_equal #[0b00000011, 0, 1, 2, 3] msg.header

  msg = coap.TcpMessage
  msg.token = coap.Token
    ByteArray 3: it + 1
  expect_bytes_equal #[0b00000011, 0, 1, 2, 3] msg.header

  // Payload.
  msg = coap.TcpMessage
  msg.options.add
    coap.Option.bytes
      0x42
      ByteArray 3: it + 1
  expect_bytes_equal #[0b01010000, 0, 0b1101_0011, 0x35, 1, 2, 3] msg.header

  // Options.
  msg = coap.TcpMessage
  msg.options.add
    coap.Option.bytes
      1
      ByteArray 0
  msg.options.add
    coap.Option.bytes
      3
      ByteArray 0
  expect_bytes_equal #[0b00100000, 0, 0b0001_0000, 0b0010_0000] msg.header
