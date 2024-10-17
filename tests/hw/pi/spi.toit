// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import gpio
import host.os
import monitor
import spi

FREQUENCY ::= 4_000

main:
  test --cpol=0 --cpha=0
  test --cpol=0 --cpha=1
  test --cpol=1 --cpha=0
  test --cpol=1 --cpha=1
  print "ALL TESTS PASSED"

test --cpol/int --cpha/int:
  mode := cpol << 1 | cpha
  device := spi.Device --path="/dev/spidev0.0" --frequency=FREQUENCY --mode=mode

  MEASURE_MOSI ::= os.env.get "SPI_MEASURE_MOSI"
  MEASURE_SCLK ::= os.env.get "SPI_MEASURE_SCLK"
  MEASURE_CS ::= os.env.get "SPI_MEASURE_CS"
  if not MEASURE_MOSI or not MEASURE_SCLK or not MEASURE_CS:
    print "SPI_MEASURE_MOSI, SPI_MEASURE_SCLK, or SPI_MEASURE_CS environment variable not set"
    exit 1

  pin-mosi := gpio.Pin.linux --name=MEASURE_MOSI --input
  pin-sclk := gpio.Pin.linux --name=MEASURE_SCLK --input
  pin-cs := gpio.Pin.linux --name=MEASURE_CS --input

  idle-clk-level := cpol
  on-from-idle-edge := cpha == 0
  received-latch := monitor.Latch
  //expect-equals idle-clk-level pin-sclk.get

  ready-latch := monitor.Latch
  task::
    ready-latch.set true
    while pin-cs.get == 1:  // By default CS is active low.
      yield

    expect-equals idle-clk-level pin-sclk.get

    // Since we are only looking for 24 bits, we can just use an integer.
    received := 0
    24.repeat:
      // Wait for the clock to go to non-idle.
      while pin-sclk.get == idle-clk-level:

      if on-from-idle-edge:
        received = (received << 1) | pin-mosi.get

      // Wait for the clock to go to idle.
      while pin-sclk.get != idle-clk-level:

      if not on-from-idle-edge:
        received = (received << 1) | pin-mosi.get

    received-latch.set received

  ready-latch.get
  MESSAGE ::= #['O', 'K', '!']
  device.write MESSAGE
  response := with-timeout --ms=3_000: received-latch.get
  expected-bits := 0
  MESSAGE.do: | c/int |
    expected-bits = (expected-bits << 8) | c
  expect-equals expected-bits response
  print "OK"

  // No need to put these into a finally. If something goes wrong
  // the test will be aborted.
  pin-mosi.close
  pin-sclk.close
  pin-cs.close
  device.close
