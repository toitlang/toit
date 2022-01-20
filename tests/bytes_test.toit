// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import bytes
import expect show *
import writer show Writer

main:
  test_simple
  test_producer

test_simple:
  buffer := bytes.Buffer
  expect_equals 0 buffer.size

  empty := buffer.bytes
  expect empty.is_empty

  buffer.write "foobar"
  foobar := buffer.bytes
  expect_equals 6 foobar.size
  expect_equals "foobar" foobar.to_string

  backing := buffer.buffer
  buffer.reserve backing.size
  // Must grow, since some bytes are already used in the backing store.
  expect buffer.buffer.size > backing.size
  // Still has to have the same content.
  expect_equals "foobar" buffer.bytes.to_string

  buffer.clear
  expect_equals 0 buffer.size

  // Grow must fill the buffer with 0s, even though the original
  //   backing store was already filled with junk.
  buffer.grow 6
  zeroes := buffer.bytes
  6.repeat: expect_equals 0 zeroes[it]

  buffer.clear
  buffer.write foobar
  expect_equals "foobar" buffer.bytes.to_string

  written := buffer.write foobar 1 4
  expect_equals 3 written
  expect_equals "foobaroob" buffer.bytes.to_string

  buffer.clear
  writer := Writer buffer
  writer.write foobar
  writer.write foobar 3
  expect_equals "foobarbar" buffer.bytes.to_string

test_producer:
  ONE_ ::= [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
  ONE ::= ByteArray ONE_.size: ONE_[it]

  TWO_ ::= [99, 98, 97, 96, 95, 94, 93, 92, 91, 90, 89, 88, 87]
  TWO ::= ByteArray TWO_.size: TWO_[it]

  expectation_on_producer
    bytes.ByteArrayProducer ONE
    ONE.size
    bytes.ByteArrayProducer TWO
    TWO.size
    ONE
    0
    TWO
    0

  expectation_on_producer
    bytes.ByteArrayProducer ONE 3
    ONE.size - 3
    bytes.ByteArrayProducer TWO 5
    TWO.size - 5
    ONE
    3
    TWO
    5

  expectation_on_producer
    bytes.ByteArrayProducer ONE 3 8
    8 - 3
    bytes.ByteArrayProducer TWO 5 10
    10 - 5
    ONE
    3
    TWO
    5

expectation_on_producer producer_1/bytes.Producer producer_1_size/int producer_2/bytes.Producer producer_2_size/int source_1/ByteArray offset_1/int source_2/ByteArray offset_2/int -> none:
  expect_equals producer_1_size producer_1.size
  expect_equals producer_2_size producer_2.size

  combined := ByteArray producer_1.size + producer_2.size

  producer_1.write_to combined 0
  producer_2.write_to combined producer_1.size

  combined.size.repeat:
    if it < producer_1.size:
      expect_equals source_1[it + offset_1] combined[it]
    else:
      expect_equals source_2[it + offset_2 - producer_1.size] combined[it]
