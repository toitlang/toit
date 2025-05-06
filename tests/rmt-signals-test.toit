// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import rmt show Signals

main:
  test-signals-construction
  test-signals-from-bytes
  test-signals-from-alternating
  test-signals-getters
  test-signals-setter
  test-signals-do

test-signals-construction:
  signals := Signals 4
  expect-equals 4 signals.size
  expect-equals 8 signals.bytes_.size

  signals = Signals 5
  expect-equals 5 signals.size
  expect-equals 12 signals.bytes_.size


test-signals-from-bytes:
  bytes := #[0x11, 0x22, 0x33, 0x44]
  signals := Signals.from-bytes bytes
  expect-equals 2 signals.size
  expect-bytes-equal bytes signals.bytes_

  resolution ::= 1_000_000
  signals = Signals.from-bytes --resolution=resolution bytes
  expect-equals 2 signals.size
  expect-bytes-equal bytes signals.bytes_
  expect-equals resolution signals.resolution


  bytes = #[0x11, 0x22, 0x33, 0x44, 0x55]
  expect-throw "INVALID_ARGUMENT":
    Signals.from-bytes bytes

test-signals-from-alternating:
  periods := [0,1,2,3,4]
  signals := Signals.alternating --first-level=0 periods

  level := 0
  periods.size.repeat:
    expect-equals level (signals.level it)
    level = level ^ 1
    expect-equals it (signals.period it)

  signals = Signals.alternating --first-level=1 periods
  level = 1
  periods.size.repeat:
    expect-equals level (signals.level it)
    level = level ^ 1
    expect-equals it (signals.period it)

  ns-durations := [0, 2_000, 4_000, 6_000, 8_000]
  signals = Signals.alternating --first-level=0 --ns-durations=ns-durations --resolution=500_000
  level = 0
  periods.size.repeat:
    expect-equals level (signals.level it)
    level = level ^ 1
    expected-ns := ns-durations[it]
    expect-equals expected-ns (signals.ns-duration it)
    expect-equals it (signals.period it)

  expect-throw "INVALID_ARGUMENT":
    Signals.alternating --first-level=2 []

  expect-throw "INVALID_ARGUMENT":
    Signals.alternating --first-level=0 [0x8FFF]

test-signals-getters:
  signals := Signals.alternating --first-level=0 [0, 0x7fff, 0x7fff, 0]
  expect-equals 0 (signals.level 0)
  expect-equals 0 (signals.period 0)

  expect-equals 1 (signals.level 1)
  expect-equals 0x7FFF (signals.period 1)

  expect-equals 0 (signals.level 2)
  expect-equals 0x7FFF (signals.period 2)

  expect-equals 1 (signals.level 3)
  expect-equals 0 (signals.period 3)

  resolution := 2_000_000
  signals = Signals.alternating --first-level=0 --ns-durations=[0, 500, 500, 0] --resolution=resolution
  expect-equals 0 (signals.level 0)
  expect-equals 0 (signals.period 0)
  expect-equals 0 (signals.ns-duration 0)

  expect-equals 1 (signals.level 1)
  expect-equals 1 (signals.period 1)
  expect-equals 500 (signals.ns-duration 1)

  expect-equals 0 (signals.level 2)
  expect-equals 1 (signals.period 2)
  expect-equals 500 (signals.ns-duration 2)

  expect-equals 1 (signals.level 3)
  expect-equals 0 (signals.period 3)
  expect-equals 0 (signals.ns-duration 3)

  expect-throw "OUT_OF_BOUNDS": signals.level -1
  expect-throw "OUT_OF_BOUNDS": signals.period -1
  expect-throw "OUT_OF_BOUNDS": signals.level 4
  expect-throw "OUT_OF_BOUNDS": signals.period 4

test-signals-setter:
  signals := Signals 3
  signals.do: | period level |
    expect-equals 0 period
    expect-equals 0 level

  signals.set 0 --period=8 --level=1
  expect-equals 8
    signals.period 0
  expect-equals 1
    signals.level 0

  signals.set 1 --period=0x7FFF --level=0
  expect-equals 0x7FFF
    signals.period 1
  expect-equals 0
    signals.level 1

  signals.set 2 --period=0 --level=1
  expect-equals 0
    signals.period 2
  expect-equals 1
    signals.level 0

  signals = Signals 3 --resolution=20_000_000
  signals.set 0 --ns=1_000_000 --level=1
  expect-equals 1_000_000
    signals.ns-duration 0
  expect-equals 20_000
    signals.period 0

test-signals-do:
  bytes := #[
    0x00, 0x00,
    0x01, 0x00,
    0x02, 0x00,
    0x03, 0x00
    ]
  signals := Signals.from-bytes bytes
  item-count := 0
  signals.do: | level period ns |
    expect-equals item-count period
    expect-equals 0 level
    expect-null ns
    item-count++
  expect-equals 4 item-count

  signals = Signals.from-bytes bytes --resolution=1_000_000
  item-count = 0
  signals.do: | level period ns |
    expect-equals item-count period
    expect-equals 0 level
    expect-equals (item-count * 1000) ns
    item-count++

  signals = Signals.from-bytes bytes --resolution=500_000
  item-count = 0
  signals.do: | level period ns |
    expect-equals item-count period
    expect-equals 0 level
    expect-equals (item-count * 2000) ns
    item-count++

  signals = Signals 3
  item-count = 0
  signals.do: item-count++
  expect-equals 3 item-count
