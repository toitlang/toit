// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import bytes show Buffer

main:
  buffer := Buffer  // NO-WARN
  buffer.write-int16-big-endian 0x4142
  buffer.write-int32-big-endian 0x31323334
  buffer.write-int64-big-endian 0x6162636465666768
  buffer.write "**-fish-**"
  expect-equals "AB1234abcdefgh**-fish-**" buffer.bytes.to-string

  buffer = Buffer  // NO-WARN
  buffer.write-int16-little-endian 0x4142
  buffer.write-int32-little-endian 0x31323334
  buffer.write-int64-little-endian 0x6162636465666768
  buffer.write "**-fish-**"
  expect-equals "BA4321hgfedcba**-fish-**" buffer.bytes.to-string
