// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import io show Buffer

main:
  buffer := Buffer
  buffer.big-endian.write-int8 -33
  buffer.big-endian.write-int8 33
  buffer.big-endian.write-int16 -22333
  buffer.big-endian.write-int16 22333
  buffer.big-endian.write-int24 -4444444
  buffer.big-endian.write-int24 4444444
  buffer.big-endian.write-int32 -1_234_567_890
  buffer.big-endian.write-int32 1_234_567_890
  buffer.big-endian.write-int64 5_555_555_555_555_555_555

  expect-equals -33 (buffer.big-endian.int8 --at=0)
  expect-equals 33 (buffer.big-endian.int8 --at=1)
  expect-equals -22333 (buffer.big-endian.int16 --at=2)
  expect-equals 22333 (buffer.big-endian.int16 --at=4)
  expect-equals -4444444 (buffer.big-endian.int24 --at=6)
  expect-equals 4444444 (buffer.big-endian.int24 --at=9)
  expect-equals -1_234_567_890 (buffer.big-endian.int32 --at=12)
  expect-equals 1_234_567_890 (buffer.big-endian.int32 --at=16)
  expect-equals 5_555_555_555_555_555_555 (buffer.big-endian.int64 --at=20)
