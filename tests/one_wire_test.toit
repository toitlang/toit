// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import one_wire show *
import rmt
import expect show *

main:
  test_decode_signals_to_bits
  test_decode_signals_to_bytes
  test_encode_read_signals
  test_encode_write_signals
  test_encode_write_then_read_signals

test_decode_signals_to_bits:
  signals := rmt.Signals.alternating --first_level=0 [
    24, 46,  // 0
    24, 46,  // 0
    24, 46,  // 0
    6,  64,  // 1
    6,  64,  // 1
    24, 46,  // 0
    6,  64,  // 1
    6,  64,  // 1
  ]
  expect_equals 0b11011000
    Protocol.decode_signals_to_bits_ signals
  expect_equals 0b01101100
    Protocol.decode_signals_to_bits_ signals --from=2 --bit_count=7
  expect_equals 0b0
    Protocol.decode_signals_to_bits_ signals --from=0 --bit_count=0
  expect_equals 0b1
    Protocol.decode_signals_to_bits_ signals --from=14 --bit_count=1

  // Decoding should start on a low edge (level = 0).
  expect_throw "unexpected signal":
    Protocol.decode_signals_to_bits_ signals --from=1 --bit_count=1

  expect_throw Protocol.INVALID_SIGNAL:
    Protocol.decode_signals_to_bits_ signals --from=0 --bit_count=10

  signals = rmt.Signals 2
  signals.set_signal 0 0 0
  signals.set_signal 1 0 0
  // The low edge should be followed by a high edge (level = 1).
  expect_throw "unexpected signal":
    Protocol.decode_signals_to_bits_ signals --from=0 --bit_count=1

test_decode_signals_to_bytes:
  periods := [
      // 0xD8
      24, 46,  // 0
      24, 46,  // 0
      24, 46,  // 0
      6,  64,  // 1
      6,  64,  // 1
      24, 46,  // 0
      6,  64,  // 1
      6,  64,  // 1
      // 0xCC
      24, 46,  // 0
      24, 46,  // 0
      6,  64,  // 1
      6,  64,  // 1
      24, 46,  // 0
      24, 46,  // 0
      6,  64,  // 1
      6,  64,  // 1
    ]
  signals := rmt.Signals.alternating --first_level=0 periods

  expect_bytes_equal #[0xD8]
    Protocol.decode_signals_to_bytes_ signals 1

  expect_bytes_equal #[0xCC]
    Protocol.decode_signals_to_bytes_ signals --from=1 1

  expect_bytes_equal #[0xD8, 0xCC]
    Protocol.decode_signals_to_bytes_ signals 2

  expect_bytes_equal #[]
    Protocol.decode_signals_to_bytes_ signals 0

  expect_throw Protocol.INVALID_SIGNAL:
    Protocol.decode_signals_to_bytes_ signals --from=1 2


  signals = rmt.Signals.alternating --first_level=0 #[]
  expect_bytes_equal #[]
    Protocol.decode_signals_to_bytes_ signals 0

  expect_throw Protocol.INVALID_SIGNAL:
    Protocol.decode_signals_to_bytes_ signals --from=0 1

  expect_throw Protocol.INVALID_SIGNAL:
    Protocol.decode_signals_to_bytes_ signals --from=1 1

test_encode_read_signals:
  signals := rmt.Signals 16

  Protocol.encode_read_signals_ signals --bit_count=8

  8.repeat:
    expect_equals 0
      signals.signal_level it * 2
    expect_equals Protocol.READ_INIT_TIME_STD
      signals.signal_period it * 2
    expect_equals 1
      signals.signal_level it * 2 + 1
    expect_equals Protocol.IO_TIME_SLOT - Protocol.READ_INIT_TIME_STD
      signals.signal_period it * 2 + 1

  signals = rmt.Signals 32

  Protocol.encode_read_signals_ signals --from=16 --bit_count=8

  // The first 16 signals are untouched.
  16.repeat:
    expect_equals 0
      signals.signal_level it
    expect_equals 0
      signals.signal_period it

  // The remaining 16 signals are encoded for reading.
  8.repeat:
    i := 16 + it * 2
    expect_equals 0
      signals.signal_level i
    expect_equals Protocol.READ_INIT_TIME_STD
      signals.signal_period i
    expect_equals 1
      signals.signal_level i + 1
    expect_equals Protocol.IO_TIME_SLOT - Protocol.READ_INIT_TIME_STD
      signals.signal_period i + 1

test_encode_write_signals:
  periods := [
    // 0xDA
    60, 10,  // 0
    6,  64,  // 1
    60, 10,  // 0
    6,  64,  // 1
    6,  64,  // 1
    60, 10,  // 0
    6,  64,  // 1
    6,  64,  // 1
  ]
  signals := rmt.Signals 16
  Protocol.encode_write_signals_ signals 0xDA
  8.repeat:
    expect_equals 0
      signals.signal_level it * 2
    expect_equals periods[it * 2]
      signals.signal_period it * 2
    expect_equals 1
      signals.signal_level it * 2 + 1
    expect_equals periods[it * 2 + 1]
      signals.signal_period it * 2 + 1

  signals = rmt.Signals 16
  Protocol.encode_write_signals_ signals 0xDA --count=6
  6.repeat:
    expect_equals 0
      signals.signal_level it * 2
    expect_equals periods[it * 2]
      signals.signal_period it * 2
    expect_equals 1
      signals.signal_level it * 2 + 1
    expect_equals periods[it * 2 + 1]
      signals.signal_period it * 2 + 1

  signals = rmt.Signals 32
  Protocol.encode_write_signals_ signals 0xDA --from=16

  // The first 16 signals are untouched.
  16.repeat:
    expect_equals 0
      signals.signal_level it
    expect_equals 0
      signals.signal_period it

  // The remaining 16 signals are encoded for writing 0xDA.
  8.repeat:
    i := 16 + it * 2
    expect_equals 0
      signals.signal_level i
    expect_equals periods[it * 2]
      signals.signal_period i
    expect_equals 1
      signals.signal_level i + 1
    expect_equals periods[it * 2 + 1]
      signals.signal_period i + 1

test_encode_write_then_read_signals:
  bytes := #[0x11, 0x22]
  write_periods := [
    // 0x11
    6,  64,  // 1
    60, 10,  // 0
    60, 10,  // 0
    60, 10,  // 0
    6,  64,  // 1
    60, 10,  // 0
    60, 10,  // 0
    60, 10,  // 0
    // 0x22
    60, 10,  // 0
    6,  64,  // 1
    60, 10,  // 0
    60, 10,  // 0
    60, 10,  // 0
    6,  64,  // 1
    60, 10,  // 0
    60, 10,  // 0
  ]

  signals := Protocol.encode_write_then_read_signals_ bytes 2

  16.repeat:
    expect_equals 0
      signals.signal_level it * 2
    expect_equals write_periods[it * 2]
      signals.signal_period it * 2
    expect_equals 1
      signals.signal_level it * 2 + 1
    expect_equals write_periods[it * 2 + 1]
      signals.signal_period it * 2 + 1

  16.repeat:
    i := 32 + it * 2
    expect_equals 0
      signals.signal_level i
    expect_equals Protocol.READ_INIT_TIME_STD
      signals.signal_period i
    expect_equals 1
      signals.signal_level i + 1
    expect_equals Protocol.IO_TIME_SLOT - Protocol.READ_INIT_TIME_STD
      signals.signal_period i + 1
