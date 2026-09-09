// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import .hw.ec618.framed-control

main:
  first := encode-frame "first"
  second := encode-frame "second"
  corrupted := encode-frame "bad"
  corrupted[3] ^= 1

  decoder := FrameDecoder
  decoder.add #[0x00, 0xff, MAGIC-0]
  expect-null decoder.take
  decoder.add first[1 .. 4]
  expect-null decoder.take
  decoder.add first[4 ..] + corrupted + second
  expect-equals "first" decoder.take
  expect-equals "second" decoder.take
  expect-null decoder.take
