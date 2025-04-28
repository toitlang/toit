// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import io
import coap.tcp as coap
import coap.message as coap
import coap.option as coap
import expect show *

import .coap-client-test

expect-exception exception [code]:
  expect-equals
    exception
    catch code

main:
  test-parse-valid-message
  test-parse-invalid-message

  test-to-byte-array

parse data/ByteArray -> coap.TcpMessage?:
  return coap.TcpMessage.parse
    TestTransport
    io.Reader data

test-parse-valid-message:
  // Empty message.
  msg := parse #[0b00000000, 0]
  expect-equals 0 msg.code

  // Fields.
  msg = parse #[0b00000000, 0b010_01001]
  expect-equals 2 msg.code-class
  expect-equals 9 msg.code-detail

  // Options.
  msg = parse #[0b00100000, 0, 0b00110001, 0x42]
  expect-equals 1 msg.options.size
  expect-equals 3 msg.options[0].number
  expect-bytes-equal #[0x42] msg.options[0].value

  msg = parse #[0b01110000, 0, 0b00010000, 0b00100000, 0b11100000, 3, 1, 0b11010000, 5]
  expect-equals 4 msg.options.size
  expect-equals 1 msg.options[0].number
  expect-equals 3 msg.options[1].number
  expect-equals 1041 msg.options[2].number
  expect-equals 1059 msg.options[3].number

  // Payload.
  msg = parse #[0b00100000, 0, 0xff, 0x42]
  expect-bytes-equal #[0x42] msg.read-payload

  msg = parse #[0b01000000, 0, 0b00110001, 0x42, 0xff, 0x42]
  expect-equals 1 msg.options.size
  expect-bytes-equal #[0x42] msg.read-payload

  // Token.
  msg = parse #[0b00000100, 0, 0x42, 0x43, 0x44, 0x45]
  expect-equals
    coap.Token #[0x42, 0x43, 0x44, 0x45]
    msg.token

  // End of stream.
  expect-null
    parse #[]

test-parse-invalid-message:
  // Bad TKL.
  expect-exception "FORMAT_ERROR":
    parse #[0b00001111, 0]
  expect-exception "UNEXPECTED_END_OF_READER":
    parse #[0b00000111, 0]

  // Bad option.
  expect-exception "FORMAT_ERROR":
    parse #[0b00010000, 0, 0b11110000]
  expect-exception "FORMAT_ERROR":
    parse #[0b00010000, 0, 0b00001111]
  expect-exception "OUT_OF_RANGE":
    parse #[0b00010000, 0, 0b11010000]
  expect-exception "OUT_OF_RANGE":
    parse #[0b00010000, 0, 0b11100000]
  expect-exception "OUT_OF_RANGE":
    parse #[0b00010000, 0, 0b00000001]

test-to-byte-array:
  msg := coap.TcpMessage
  expect-bytes-equal #[0b00000000, 0] msg.header

  msg = coap.TcpMessage
  msg.code = coap.CODE-CONTENT
  expect-bytes-equal #[0b00000000, 0b01000101] msg.header

  msg = coap.TcpMessage
  msg.code = coap.CODE-GATEWAY-TIMEOUT
  expect-bytes-equal #[0b00000000, 0b10100100] msg.header

  // Token.
  msg = coap.TcpMessage
  msg.token = coap.Token
    ByteArray 3: it + 1
  expect-bytes-equal #[0b00000011, 0, 1, 2, 3] msg.header

  msg = coap.TcpMessage
  msg.token = coap.Token
    ByteArray 3: it + 1
  expect-bytes-equal #[0b00000011, 0, 1, 2, 3] msg.header

  // Payload.
  msg = coap.TcpMessage
  msg.options.add
    coap.Option.bytes
      0x42
      ByteArray 3: it + 1
  expect-bytes-equal #[0b01010000, 0, 0b1101_0011, 0x35, 1, 2, 3] msg.header

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
  expect-bytes-equal #[0b00100000, 0, 0b0001_0000, 0b0010_0000] msg.header
