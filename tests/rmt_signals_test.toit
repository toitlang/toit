// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import rmt show Signals

main:
  test_signals_construction
  test_signals_getters
  test_signals_setter
  test_signals_do

test_signals_construction:
  signals := Signals 4
  expect_equals 4 signals.size
  expect_equals 8 signals.bytes_.size

  signals = Signals 5
  expect_equals 5 signals.size
  expect_equals 12 signals.bytes_.size

  bytes := #[0x11, 0x22, 0x33, 0x44]
  signals = Signals.from_bytes bytes
  expect_equals 2 signals.size
  expect_bytes_equal bytes signals.bytes_

  bytes = #[0x11, 0x22, 0x33, 0x44, 0x55]
  expect_throw "INVALID_ARGUMENT":
    Signals.from_bytes bytes

test_signals_getters:
  signals := Signals.alternating --first_level=0 [0, 0x7fff, 0x7fff, 0]
  expect_equals 0 (signals.signal_level 0)
  expect_equals 0 (signals.signal_period 0)

  expect_equals 1 (signals.signal_level 1)
  expect_equals 0x7FFF (signals.signal_period 1)

  expect_equals 0 (signals.signal_level 2)
  expect_equals 0x7FFF (signals.signal_period 2)

  expect_equals 1 (signals.signal_level 3)
  expect_equals 0 (signals.signal_period 3)

  expect_throw "OUT_OF_BOUNDS": signals.signal_level -1
  expect_throw "OUT_OF_BOUNDS": signals.signal_period -1
  expect_throw "OUT_OF_BOUNDS": signals.signal_level 4
  expect_throw "OUT_OF_BOUNDS": signals.signal_period 4

test_signals_setter:
  signals := Signals 3
  signals.do: | period level |
    expect_equals 0 period
    expect_equals 0 level

  signals.set_signal 0 8 1
  expect_equals 8
    signals.signal_period 0
  expect_equals 1
    signals.signal_level 0

  signals.set_signal 1 0x7FFF 0
  expect_equals 0x7FFF
    signals.signal_period 1
  expect_equals 0
    signals.signal_level 1

  signals.set_signal 2 0 1
  expect_equals 0
    signals.signal_period 2
  expect_equals 1
    signals.signal_level 0

test_signals_do:
  bytes := #[
    0x00, 0x00,
    0x01, 0x00,
    0x02, 0x00,
    0x03, 0x00
    ]
  signals := Signals.from_bytes bytes
  item_count := 0
  signals.do: | period level |
    expect_equals item_count period
    expect_equals 0 level
    item_count++
  expect_equals 4 item_count

  signals = Signals 3
  item_count = 0
  signals.do: item_count++
  expect_equals 3 item_count
