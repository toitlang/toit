// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import bytes
import expect show *
import writer show Writer

main:
  test-simple
  test-producer

test-simple:
  buffer := bytes.Buffer  // NO-WARN
  expect-equals 0 buffer.size

  empty := buffer.bytes
  expect empty.is-empty

  buffer.write "foobar"
  foobar := buffer.bytes
  expect-equals 6 foobar.size
  expect-equals "foobar" foobar.to-string

  backing := buffer.buffer
  buffer.reserve backing.size
  // Must grow, since some bytes are already used in the backing store.
  expect buffer.buffer.size > backing.size
  // Still has to have the same content.
  expect-equals "foobar" buffer.bytes.to-string

  buffer.clear
  expect-equals 0 buffer.size

  // Grow must fill the buffer with 0s, even though the original
  //   backing store was already filled with junk.
  buffer.grow 6
  zeros := buffer.bytes
  6.repeat: expect-equals 0 zeros[it]

  buffer.clear
  buffer.write foobar
  expect-equals "foobar" buffer.bytes.to-string

  written := buffer.write foobar 1 4
  expect-equals 3 written
  expect-equals "foobaroob" buffer.bytes.to-string

  buffer.clear
  writer := Writer buffer  // NO-WARN
  writer.write foobar
  writer.write foobar 3
  expect-equals "foobarbar" buffer.bytes.to-string

test-producer:
  ONE_ ::= [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
  ONE ::= ByteArray ONE_.size: ONE_[it]

  TWO_ ::= [99, 98, 97, 96, 95, 94, 93, 92, 91, 90, 89, 88, 87]
  TWO ::= ByteArray TWO_.size: TWO_[it]

  expectation-on-producer
    bytes.ByteArrayProducer ONE  // NO-WARN
    ONE.size
    bytes.ByteArrayProducer TWO  // NO-WARN
    TWO.size
    ONE
    0
    TWO
    0

  expectation-on-producer
    bytes.ByteArrayProducer ONE 3  // NO-WARN
    ONE.size - 3
    bytes.ByteArrayProducer TWO 5  // NO-WARN
    TWO.size - 5
    ONE
    3
    TWO
    5

  expectation-on-producer
    bytes.ByteArrayProducer ONE 3 8  // NO-WARN
    8 - 3
    bytes.ByteArrayProducer TWO 5 10  // NO-WARN
    10 - 5
    ONE
    3
    TWO
    5

expectation-on-producer producer-1/bytes.Producer producer-1-size/int producer-2/bytes.Producer producer-2-size/int source-1/ByteArray offset-1/int source-2/ByteArray offset-2/int -> none:
  expect-equals producer-1-size producer-1.size
  expect-equals producer-2-size producer-2.size

  combined := ByteArray producer-1.size + producer-2.size

  producer-1.write-to combined 0
  producer-2.write-to combined producer-1.size

  combined.size.repeat:
    if it < producer-1.size:
      expect-equals source-1[it + offset-1] combined[it]
    else:
      expect-equals source-2[it + offset-2 - producer-1.size] combined[it]
