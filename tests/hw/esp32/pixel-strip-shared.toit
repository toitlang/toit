// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import rmt

import .variants

BYTES-PER-PIXEL ::= 3
FRAME-COUNT ::= 8
RESOLUTION ::= 20_000_000
TIMING-SLACK-TICKS ::= 3

DATA-PIN ::= Variant.CURRENT.pixel-strip-data-pin
READY-PIN ::= Variant.CURRENT.pixel-strip-ready-pin

// Classic ESP32 RMT input has no DMA. Keep its test within dedicated RMT
//   memory, while DMA-capable variants exercise a 1,000-pixel frame that
//   requires peripheral rebuffering in every pixel-strip backend.
PIXELS ::= rmt.DMA-SUPPORTED ? 1_000 : 7

red-value pixel/int frame/int -> int:
  return (pixel * 17 + frame * 29 + 1) & 0xff

green-value pixel/int frame/int -> int:
  return (pixel * 31 + frame * 13 + 0x55) & 0xff

blue-value pixel/int frame/int -> int:
  return (pixel * 7 + frame * 47 + 0xaa) & 0xff

fill-frame frame/int red/ByteArray green/ByteArray blue/ByteArray -> none:
  PIXELS.repeat: | pixel |
    red[pixel] = red-value pixel frame
    green[pixel] = green-value pixel frame
    blue[pixel] = blue-value pixel frame

expected-grb frame/int -> ByteArray:
  return ByteArray PIXELS * BYTES-PER-PIXEL:
    pixel := it / BYTES-PER-PIXEL
    component := it % BYTES-PER-PIXEL
    component == 0
        ? green-value pixel frame
        : component == 1 ? red-value pixel frame : blue-value pixel frame

// The final low period turns into the RMT end marker because the line never
//   transitions high again after the frame.
EXPECTED-BIT-COUNT ::= PIXELS * BYTES-PER-PIXEL * 8
RMT-CAPTURE-BYTES ::= EXPECTED-BIT-COUNT * 2 * rmt.Signals.BYTES-PER-SIGNAL
RMT-MEMORY-BLOCKS ::= (RMT-CAPTURE-BYTES + rmt.BYTES-PER-MEMORY-BLOCK - 1) / rmt.BYTES-PER-MEMORY-BLOCK

expect-close-to expected/int actual/int --transition/int:
  expect (expected - actual).abs <= TIMING-SLACK-TICKS
      --message="Transition $transition: expected $expected ticks, got $actual ticks"

validate-capture signals/rmt.Signals backend/string frame/int:
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

  expected := expected-grb frame
  decoded := ByteArray expected.size
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

  expect-bytes-equal expected decoded

  signals.size.repeat: | index |
    if index >= transition-count:
      expect-equals 0 (signals.period index)
