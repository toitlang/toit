// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import rmt

import .variants

BYTES-PER-PIXEL ::= 3
RESOLUTION ::= 20_000_000
TIMING-SLACK-TICKS ::= 3

DATA-PIN ::= Variant.CURRENT.pixel-strip-data-pin
READY-PIN ::= Variant.CURRENT.pixel-strip-ready-pin
BASE-RED ::= #[0x00, 0xff, 0x80, 0x01, 0xaa, 0x55, 0x96]
BASE-GREEN ::= #[0xff, 0x00, 0x7f, 0xfe, 0x55, 0xaa, 0x69]
BASE-BLUE ::= #[0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde]

// Classic ESP32 RMT input has no DMA. Keep its test within dedicated RMT
//   memory, while DMA-capable variants exercise a frame that requires
//   peripheral rebuffering in every pixel-strip backend.
PIXELS ::= rmt.DMA-SUPPORTED ? 200 : BASE-RED.size

RED ::= ByteArray PIXELS: BASE-RED[it % BASE-RED.size]
GREEN ::= ByteArray PIXELS: BASE-GREEN[it % BASE-GREEN.size]
BLUE ::= ByteArray PIXELS: BASE-BLUE[it % BASE-BLUE.size]

EXPECTED-GRB ::= ByteArray PIXELS * BYTES-PER-PIXEL:
  pixel-index := it / BYTES-PER-PIXEL
  component := it % BYTES-PER-PIXEL
  component == 0
      ? GREEN[pixel-index]
      : component == 1 ? RED[pixel-index] : BLUE[pixel-index]

// The final low period turns into the RMT end marker because the line never
//   transitions high again after the frame.
EXPECTED-BIT-COUNT ::= PIXELS * BYTES-PER-PIXEL * 8
RMT-CAPTURE-BYTES ::= EXPECTED-BIT-COUNT * 2 * rmt.Signals.BYTES-PER-SIGNAL
RMT-MEMORY-BLOCKS ::= (RMT-CAPTURE-BYTES + rmt.BYTES-PER-MEMORY-BLOCK - 1) / rmt.BYTES-PER-MEMORY-BLOCK

expect-close-to expected/int actual/int --transition/int:
  expect (expected - actual).abs <= TIMING-SLACK-TICKS
      --message="Transition $transition: expected $expected ticks, got $actual ticks"

validate-capture signals/rmt.Signals backend/string:
  transition-count := signals.size
  while transition-count > 0 and (signals.period (transition-count - 1)) == 0:
    transition-count--

  expect signals.size > transition-count
      --message="RMT capture has no end marker"
  expect transition-count % 2 == 1
      --message="Pixel stream ended midway through a bit"

  bit-count := (transition-count + 1) / 2
  expect bit-count >= EXPECTED-BIT-COUNT
      --message="Expected at least $EXPECTED-BIT-COUNT bits, got $bit-count"
  extra-bit-count := bit-count - EXPECTED-BIT-COUNT

  decoded := ByteArray EXPECTED-GRB.size
  bit-count.repeat: | bit-index |
    high-index := bit-index * 2
    low-index := high-index + 1
    high-ticks := signals.period high-index

    expect-equals 1 (signals.level high-index)

    bit := high-ticks > 10 ? 1 : 0
    expected-high := backend == "rmt"
        ? (bit == 0 ? 7 : 14)
        : (bit == 0 ? 8 : 16)
    expect-close-to expected-high high-ticks --transition=high-index
    if low-index < transition-count:
      low-ticks := signals.period low-index
      expected-low := backend == "rmt"
          ? (bit == 0 ? 16 : 12)
          : (bit == 0 ? 16 : 8)
      expect-equals 0 (signals.level low-index)
      expect-close-to expected-low low-ticks --transition=low-index

    if bit-index >= extra-bit-count:
      expected-bit-index := bit-index - extra-bit-count
      byte-index := expected-bit-index / 8
      bit-offset := 7 - expected-bit-index % 8
      decoded[byte-index] |= bit << bit-offset

  expect-bytes-equal EXPECTED-GRB decoded

  signals.size.repeat: | index |
    if index >= transition-count:
      expect-equals 0 (signals.period index)
