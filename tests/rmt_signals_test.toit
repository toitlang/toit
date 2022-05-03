// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import rmt show Signals

main:
  test_signals_construction
  test_signals_from_bytes
  test_signals_from_alternating
  test_signals_getters
  test_signals_setter
  test_signals_do

test_signals_construction:
  signals := Signals 4
  expect_equals 4 signals.size
  expect_equals 12 signals.bytes_.size

  signals = Signals 5
  expect_equals 5 signals.size
  expect_equals 12 signals.bytes_.size


test_signals_from_bytes:
  bytes := #[0x11, 0x22, 0x33, 0x44]
  signals := Signals.from_bytes bytes
  expect_equals 2 signals.size
  expect_bytes_equal bytes signals.bytes_

  bytes = #[0x11, 0x22, 0x33, 0x44, 0x55]
  expect_throw "INVALID_ARGUMENT":
    Signals.from_bytes bytes

test_signals_from_alternating:
  periods := [0,1,2,3,4]
  signals := Signals.alternating --first_level=0 periods

  level := 0
  periods.size.repeat:
    expect_equals level (signals.level it)
    level = level ^ 1
    expect_equals it (signals.period it)

  signals = Signals.alternating --first_level=1 periods
  level = 1
  periods.size.repeat:
    expect_equals level (signals.level it)
    level = level ^ 1
    expect_equals it (signals.period it)

  expect_throw "INVALID_ARGUMENT":
    Signals.alternating --first_level=2 []

  expect_throw "INVALID_ARGUMENT":
    Signals.alternating --first_level=0 [0x8FFF]

test_signals_getters:
  signals := Signals.alternating --first_level=0 [0, 0x7fff, 0x7fff, 0]
  expect_equals 0 (signals.level 0)
  expect_equals 0 (signals.period 0)

  expect_equals 1 (signals.level 1)
  expect_equals 0x7FFF (signals.period 1)

  expect_equals 0 (signals.level 2)
  expect_equals 0x7FFF (signals.period 2)

  expect_equals 1 (signals.level 3)
  expect_equals 0 (signals.period 3)

  expect_throw "OUT_OF_BOUNDS": signals.level -1
  expect_throw "OUT_OF_BOUNDS": signals.period -1
  expect_throw "OUT_OF_BOUNDS": signals.level 4
  expect_throw "OUT_OF_BOUNDS": signals.period 4

test_signals_setter:
  signals := Signals 3
  signals.do: | period level |
    expect_equals 0 period
    expect_equals 0 level

  signals.set 0 --period=8 --level=1
  expect_equals 8
    signals.period 0
  expect_equals 1
    signals.level 0

  signals.set 1 --period=0x7FFF --level=0
  expect_equals 0x7FFF
    signals.period 1
  expect_equals 0
    signals.level 1

  signals.set 2 --period=0 --level=1
  expect_equals 0
    signals.period 2
  expect_equals 1
    signals.level 0

test_signals_do:
  bytes := #[
    0x00, 0x00,
    0x01, 0x00,
    0x02, 0x00,
    0x03, 0x00
    ]
  signals := Signals.from_bytes bytes
  item_count := 0
  signals.do: | level  period |
    expect_equals item_count period
    expect_equals 0 level
    item_count++
  expect_equals 4 item_count

  signals = Signals 3
  item_count = 0
  signals.do: item_count++
  expect_equals 3 item_count
