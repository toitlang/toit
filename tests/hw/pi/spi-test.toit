// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio
import host.os
import spi

import ..shared.spi as shared

FREQUENCY ::= 4_000

main:
  TEST_CS ::= os.env.get "SPI_TEST_CS"
  TEST_SCLK ::= os.env.get "SPI_TEST_SCLK"
  TEST_MOSI ::= os.env.get "SPI_TEST_MOSI"
  TEST_MISO ::= os.env.get "SPI_TEST_MISO"

  if not TEST_CS or not TEST_SCLK or not TEST_MOSI or not TEST_MISO:
    print "SPI_TEST_CS, SPI_TEST_SCLK, SPI_TEST_MOSI, or TEST_MISO environment variable not set"
    exit 1

  pin-cs := gpio.Pin.linux --name=TEST_CS
  pin-sclk := gpio.Pin.linux --name=TEST_SCLK
  pin-mosi := gpio.Pin.linux --name=TEST_MOSI
  pin-miso := gpio.Pin.linux --name=TEST_MISO

  slave := shared.SlaveBitBang
      --cs=pin-cs
      --sclk=pin-sclk
      --mosi=pin-mosi
      --miso=pin-miso

  shared.test-spi
      --create-device=: spi.Device --path="/dev/spidev0.0" --frequency=FREQUENCY --mode=it
      --slave=slave

  // No need to put these into a finally. If something goes wrong
  // the test will be aborted.
  pin-cs.close
  pin-sclk.close
  pin-mosi.close
  pin-miso.close

  print "ALL TESTS PASSED"
