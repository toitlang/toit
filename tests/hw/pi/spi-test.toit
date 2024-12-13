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
  print "Running cpol=$cpol cpha=$cpha"
  mode := cpol << 1 | cpha
  device := spi.Device --path="/dev/spidev0.0" --frequency=FREQUENCY --mode=mode

  TEST_MOSI ::= os.env.get "SPI_TEST_MOSI"
  TEST_SCLK ::= os.env.get "SPI_TEST_SCLK"
  TEST_CS ::= os.env.get "SPI_TEST_CS"
  TEST_MISO ::= os.env.get "SPI_TEST_MISO"

  if not TEST_MOSI or not TEST_SCLK or not TEST_CS or not TEST_MISO:
    print "SPI_TEST_MOSI, SPI_TEST_SCLK, SPI_TEST_CS, or TEST_MISO environment variable not set"
    exit 1

  pin-mosi := gpio.Pin.linux --name=TEST_MOSI --input
  pin-sclk := gpio.Pin.linux --name=TEST_SCLK --input
  pin-cs := gpio.Pin.linux --name=TEST_CS --input
  // Start with test-miso as input. The mosi and miso pins are connected with a
  // 5k resistor, and by setting the miso pin as input the spi output is now
  // read as input.
  pin-miso := gpio.Pin.linux --name=TEST_MISO --input

  payload := "hello".to-byte-array
  data := payload.copy
  device.transfer --read data
  expect-equals payload data

  // Now drive the input to 0 or 1.
  pin-miso.configure --output

  pin-miso.set 0
  data = payload.copy
  device.transfer --read data
  expect-equals (ByteArray payload.size --initial=0) data

  pin-miso.set 1
  data = payload.copy
  device.transfer --read data
  expect-equals (ByteArray payload.size --initial=0xff) data

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
  pin-miso.close
  device.close
