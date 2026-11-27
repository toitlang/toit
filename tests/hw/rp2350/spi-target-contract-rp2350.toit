// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import gpio
import spi

/**
RP2350 SPI target argument, ownership, and lifecycle regression.

This test needs no SPI controller. CS is pulled inactive internally, so a
  BufferTarget can arm and close without external wiring.
*/

main:
  print "spi-target-contract-rp2350: mode and pin validation"
  expect-throw "INVALID_ARGUMENT":
    spi.BufferTarget --mosi=4 --miso=7 --clock=6 --cs=5 --mode=0
  expect-throw "INVALID_ARGUMENT":
    spi.BufferTarget --mosi=4 --miso=7 --clock=6 --cs=5 --mode=2
  expect-throw "INVALID_ARGUMENT":
    spi.BufferTarget --mosi=7 --miso=4 --clock=6 --cs=5 --mode=1
  expect-throw "INVALID_ARGUMENT":
    spi.BufferTarget --mosi=4 --miso=7 --clock=6 --cs=9 --mode=1
  expect-throw "PERMISSION_DENIED":
    spi.BufferTarget --mosi=0 --miso=3 --clock=2 --cs=1 --mode=1

  borrowed/any := gpio.Pin 4 --input
  try:
    // Dynamic calls are rejected by the public numeric parameter type before
    // the deprecated gpio.Pin value can reach the native primitive.
    expect-throw "AS_CHECK_FAILED":
      spi.BufferTarget  // @no-warn
          --mosi=borrowed
          --miso=7
          --clock=6
          --cs=5
          --mode=1
  finally:
    borrowed.close

  print "spi-target-contract-rp2350: shared controller and pin ownership"
  target0 := spi.BufferTarget
      --mosi=4
      --miso=7
      --clock=6
      --cs=5
      --mode=1
      --dma=false
  independent := gpio.Pin 32 --input --pull-up
  try:
    expect-throw "ALREADY_IN_USE": spi.Bus --mosi=7 --miso=4 --clock=6
    [4, 5, 6, 7].do: | pin/int |
      expect-throw "ALREADY_IN_USE": gpio.Pin pin --input
    // The raw CS handler must coexist with the ordinary GPIO bank callback.
    expect-equals 1 independent.get
  finally:
    independent.close
    target0.close

  bus0 := spi.Bus --mosi=7 --miso=4 --clock=6
  bus0.close

  print "spi-target-contract-rp2350: RP2350B high bank"
  target-high := spi.BufferTarget
      --mosi=32
      --miso=35
      --clock=34
      --cs=33
      --mode=3
      --dma=true
  try:
    [32, 33, 34, 35].do: | pin/int |
      expect-throw "ALREADY_IN_USE": gpio.Pin pin --input
    expect-throw "ALREADY_IN_USE":
      spi.BufferTarget
          --mosi=16
          --miso=19
          --clock=18
          --cs=17
          --mode=1
          --dma=false
  finally:
    target-high.close

  [32, 33, 34, 35].do: | pin/int |
    reopened := gpio.Pin pin --input
    reopened.close

  print "spi-target-contract-rp2350: both controllers"
  target0 = spi.BufferTarget
      --mosi=4
      --miso=7
      --clock=6
      --cs=5
      --mode=1
      --dma=false
  target1 := spi.BufferTarget
      --mosi=8
      --miso=11
      --clock=10
      --cs=9
      --mode=3
      --dma=false
  target1.close
  target0.close
  print "spi-target-contract-rp2350: PASS"
