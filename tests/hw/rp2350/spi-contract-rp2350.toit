// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import gpio
import spi

/**
RP2350 SPI argument, ownership, cancellation, and lifecycle regression.

No SPI target is needed. The ESP32 rig peer must leave GP4 through GP11 as
  inputs because this test drives the SPI0 pins briefly.
*/

open-spi0 -> spi.Bus:
  return spi.Bus --mosi=7 --miso=4 --clock=6

open-spi1 -> spi.Bus:
  return spi.Bus --mosi=11 --miso=8 --clock=10

main:
  print "spi-contract-rp2350: argument validation"
  borrowed := gpio.Pin 35 --input
  try:
    expect-throw "INVALID_ARGUMENT":
      spi.Bus --mosi=borrowed --miso=32 --clock=34  // @no-warn
  finally:
    borrowed.close

  expect-throw "INVALID_ARGUMENT": spi.Bus --mosi=-5 --miso=4 --clock=6
  expect-throw "INVALID_ARGUMENT": spi.Bus --clock=6
  expect-throw "INVALID_ARGUMENT": spi.Bus --mosi=5 --miso=4 --clock=6
  expect-throw "INVALID_ARGUMENT": spi.Bus --mosi=11 --miso=4 --clock=6
  expect-throw "INVALID_ARGUMENT": spi.Bus --mosi=7 --miso=48 --clock=6
  expect-throw "PERMISSION_DENIED": spi.Bus --mosi=3 --miso=0 --clock=2

  bus0 := open-spi0
  bus1 := open-spi1
  try:
    print "spi-contract-rp2350: both controllers reserved"
    expect-throw "ALREADY_IN_USE":
      spi.Bus --mosi=35 --miso=32 --clock=34
    expect-throw "ALREADY_IN_USE": gpio.Pin 7 --input
    expect-throw "ALREADY_IN_USE": gpio.Pin 4 --input
    expect-throw "ALREADY_IN_USE": gpio.Pin 6 --input

    borrowed-cs := gpio.Pin 33 --input
    try:
      expect-throw "INVALID_ARGUMENT":
        bus0.device --cs=borrowed-cs --frequency=1_000_000  // @no-warn
    finally:
      borrowed-cs.close

    expect-throw "INVALID_ARGUMENT":
      bus0.device --cs=-5 --frequency=1_000_000
    expect-throw "PERMISSION_DENIED":
      bus0.device --cs=0 --frequency=1_000_000
    expect-throw "INVALID_ARGUMENT":
      bus0.device --frequency=0
    expect-throw "INVALID_ARGUMENT":
      bus0.device --frequency=1
    expect-throw "INVALID_ARGUMENT":
      bus0.device --frequency=1_000_000_000
    expect-throw "INVALID_ARGUMENT":
      bus0.device --frequency=1_000_000 --command-bits=3
    expect-throw "UNIMPLEMENTED":
      bus0.device --frequency=1_000_000 --cs-setup-cycles=1

    device := bus0.device --cs=5 --dc=9 --frequency=1_000_000
    try:
      expect-throw "ALREADY_IN_USE": gpio.Pin 5 --input
      expect-throw "ALREADY_IN_USE": gpio.Pin 9 --input
      expect-throw "ALREADY_IN_USE":
        bus0.device --cs=5 --frequency=1_000_000
    finally:
      device.close

    cs := gpio.Pin 5 --input
    dc := gpio.Pin 9 --input
    cs.close
    dc.close
  finally:
    bus1.close
    bus0.close

  // A slow transfer gives the deadline time to exercise native abort. The
  // following transfer verifies that resetting the PL022 leaves it reusable.
  bus := open-spi0
  slow := bus.device --cs=5 --frequency=3_000
  try:
    expect-throw DEADLINE-EXCEEDED-ERROR:
      with-timeout --ms=5:
        slow.write (ByteArray 256 --initial=0xa5)
    with-timeout --ms=1_000: slow.write #[0x5a]
  finally:
    slow.close

  child := bus.device --cs=5 --frequency=1_000_000
  bus.close
  expect-throw "CLOSED": child.write #[1]
  child.close

  pin4 := gpio.Pin 4 --input
  pin5 := gpio.Pin 5 --input
  pin6 := gpio.Pin 6 --input
  pin7 := gpio.Pin 7 --input
  pin4.close
  pin5.close
  pin6.close
  pin7.close

  reopened0 := open-spi0
  reopened0.close
  reopened1 := open-spi1
  reopened1.close

  mosi-only := spi.Bus --mosi=7 --clock=6
  mosi-only.close
  miso-only := spi.Bus --miso=4 --clock=6
  miso-only.close
  print "spi-contract-rp2350: PASS"
