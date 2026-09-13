// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor
import spi

import .test
import .variants

main:
  run-test: test

test:
  bus := spi.Bus
      --clock=Variant.CURRENT.unconnected-pin3
      --mosi=Variant.CURRENT.unconnected-pin2
  slow := bus.device --cs=null --frequency=100_000
  fast := bus.device --cs=null --frequency=1_000_000
  payload := ByteArray 4092 --initial=0x96

  // A deadline interrupts the wait. ESP32 must drain its accepted transfer
  // while allowing other tasks to run, then permit immediate bus reuse.
  ticks := 0
  running := true
  ticker-done := monitor.Latch
  task::
    while running:
      ticks++
      sleep --ms=1
    ticker-done.set true
  try:
    expect-throw DEADLINE-EXCEEDED-ERROR:
      with-timeout --ms=10: slow.transfer payload
    expect ticks > 10
    fast.transfer #[1, 2, 3]

    // A second device waits for the reservation without entering the native
    // driver. Its deadline must not abort the reserving task's transaction.
    reserved := monitor.Latch
    release := monitor.Latch
    completed := monitor.Latch
    task::
      error := catch:
        slow.with-reserved-bus:
          expect-throw "INVALID_STATE": fast.transfer #[0]
          expect-throw "INVALID_STATE": fast.close
          expect-throw "INVALID_STATE": fast.with-reserved-bus: null
          expect-throw "INVALID_STATE": bus.device --frequency=1_000_000
          reserved.set true
          release.get
          slow.transfer #[4]
      completed.set error
    reserved.get
    expect-throw DEADLINE-EXCEEDED-ERROR:
      with-timeout --ms=10: fast.transfer #[5]
    release.set true
    expect-equals null completed.get
    fast.transfer #[6]
  finally:
    running = false
    ticker-done.get
    bus.close
  expect-throw "CLOSED": slow.transfer #[7]
  expect-throw "CLOSED": fast.transfer #[8]
