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
  device := spi.Device --path="/dev/spidev0.0" --frequency=FREQUENCY

  TEST_CS ::= os.env.get "SPI_TEST_CS"
  if not TEST_CS:
    print "PIN3 environment variable not set"
    exit 1

  pin-cs := gpio.Pin.linux --name=TEST_CS --input

  expect-equals 1 pin-cs.get

  device.with-reserved-bus:
    MESSAGE ::= #['O', 'K', '!']
    device.transfer MESSAGE --keep-cs-active
    expect-equals 0 pin-cs.get
    device.transfer MESSAGE
    expect-equals 1 pin-cs.get

  print "ALL TESTS PASSED"

  // No need to put these into a finally. If something goes wrong
  // the test will be aborted.
  pin-cs.close
  device.close
