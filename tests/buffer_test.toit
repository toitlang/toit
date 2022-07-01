// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import binary show *
import bytes show Buffer

main:
  buffer := Buffer
  buffer.write_int16_big_endian 0x4142
  buffer.write_int32_big_endian 0x31323334
  buffer.write_int64_big_endian 0x6162636465666768
  buffer.write "**-fish-**"
  expect_equals "AB1234abcdefgh**-fish-**" buffer.bytes.to_string

  buffer = Buffer
  buffer.write_int16_little_endian 0x4142
  buffer.write_int32_little_endian 0x31323334
  buffer.write_int64_little_endian 0x6162636465666768
  buffer.write "**-fish-**"
  expect_equals "BA4321hgfedcba**-fish-**" buffer.bytes.to_string
