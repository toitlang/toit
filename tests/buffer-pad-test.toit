// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import io show Buffer

main:
  buffer := Buffer
  buffer.pad-to --size=10
  expect-equals 10 buffer.size
  expect-equals (ByteArray 10) buffer.bytes

  buffer.pad-to --size=1  // Does nothing.
  expect-equals 10 buffer.size

  buffer.pad-to --size=12 --value=0x55
  expect-equals 12 buffer.size
  expect-equals 0 buffer[9]
  expect-equals 0x55 buffer[10]
  expect-equals 0x55 buffer[11]

  buffer.pad --alignment=4  // Does nothing.
  expect-equals 12 buffer.size

  buffer.pad --alignment=5
  expect-equals 15 buffer.size
  expect-equals 0 buffer[12]
  expect-equals 0 buffer[13]
  expect-equals 0 buffer[14]

  buffer.pad --alignment=4 --value=0x66
  expect-equals 16 buffer.size
  expect-equals 0x66 buffer[15]
