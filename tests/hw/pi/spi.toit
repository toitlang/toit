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

  PIN1-NAME ::= os.env.get "PIN1"
  PIN2-NAME ::= os.env.get "PIN2"
  PIN3-NAME ::= os.env.get "PIN3"
  if not PIN1-NAME or not PIN2-NAME or not PIN3-NAME:
    print "PIN1, PIN2, or PIN3 environment variable not set"
    exit 1

  pin-mosi := gpio.Pin.linux --name=PIN1-NAME --input
  pin-sclk := gpio.Pin.linux --name=PIN2-NAME --input
  pin-cs := gpio.Pin.linux --name=PIN3-NAME --input

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
