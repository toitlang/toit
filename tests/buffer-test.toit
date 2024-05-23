// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import io show Buffer

main:
  buffer := Buffer
  buffer.big-endian.write-int16 0x4142
  buffer.big-endian.write-int24 0x434445
  buffer.big-endian.write-int32 0x31323334
  buffer.big-endian.write-int64 0x6162636465666768
  buffer.write "**-fish-**"
  expect-equals "ABCDE1234abcdefgh**-fish-**" buffer.bytes.to-string
  expect-equals 0x4142 (buffer.big-endian.int16 --at=0)
  expect-equals 0x434445 (buffer.big-endian.int24 --at=2)
  expect-equals 0x31323334 (buffer.big-endian.int32 --at=5)

  buffer = Buffer
  buffer.little-endian.write-int16 0x4142
  buffer.little-endian.write-int24 0x434445
  buffer.little-endian.write-int32 0x31323334
  buffer.little-endian.write-int64 0x6162636465666768
  buffer.write "**-fish-**"
  expect-equals "BAEDC4321hgfedcba**-fish-**" buffer.bytes.to-string

  buffer = Buffer.with-capacity 4
  buffer.grow-by 4
  buffer.big-endian.put-int16 --at=0 0x4142
  buffer.big-endian.put-int16 --at=2 0x4344
  expect-equals "ABCD" buffer.bytes.to-string

  buffer = Buffer.with-capacity 4
  buffer.grow-by 4
  buffer.little-endian.put-int16 --at=0 0x4142
  buffer.little-endian.put-int16 --at=2 0x4344
  expect-equals "BADC" buffer.bytes.to-string

  buffer = Buffer.with-capacity 6
  buffer.grow-by 6
  buffer.big-endian.put-int24 --at=0 0x414243
  buffer.big-endian.put-int24 --at=3 0x444546
  expect-equals "ABCDEF" buffer.bytes.to-string

  buffer = Buffer.with-capacity 6
  buffer.grow-by 6
  buffer.little-endian.put-int24 --at=0 0x414243
  buffer.little-endian.put-int24 --at=3 0x444546
  expect-equals "CBAFED" buffer.bytes.to-string

  buffer = Buffer.with-capacity 8
  buffer.grow-by 8
  buffer.big-endian.put-int32 --at=0 0x31323334
  buffer.big-endian.put-int32 --at=4 0x35363738
  expect-equals "12345678" buffer.bytes.to-string

  buffer = Buffer.with-capacity 8
  buffer.grow-by 8
  buffer.little-endian.put-int32 --at=0 0x31323334
  buffer.little-endian.put-int32 --at=4 0x35363738
  expect-equals "43218765" buffer.bytes.to-string

  buffer = Buffer.with-capacity 16
  buffer.grow-by 16
  buffer.big-endian.put-int64 --at=0 0x6162636465666768
  buffer.big-endian.put-int64 --at=8 0x696a6b6c6d6e6f70
  expect-equals "abcdefghijklmnop" buffer.bytes.to-string

  buffer = Buffer.with-capacity 16
  buffer.grow-by 16
  buffer.little-endian.put-int64 --at=0 0x6162636465666768
  buffer.little-endian.put-int64 --at=8 0x696a6b6c6d6e6f70
  expect-equals "hgfedcbaponmlkji" buffer.bytes.to-string
