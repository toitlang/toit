// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests a simple pulse from the RMT peripheral.

Setup:
Connect pin 18 and 19 with a 330 Ohm resistor. The resistor isn't
  strictly necessary but can prevent accidental short circuiting.

Similarly, connect pin 21 to pin 19 with a 330 Ohm resistor. We will
  use that one to pull the line high.
*/

import rmt
import gpio
import monitor
import expect show *

import .test

RMT-PIN-1 ::= 18
RMT-PIN-2 ::= 19
RMT-PIN-3 ::= 21
RMT-PIN-4 ::= 32

main:
  run-test: test

test:
  pin1 := gpio.Pin RMT-PIN-1
  pin2 := gpio.Pin RMT-PIN-2
  pin3 := gpio.Pin RMT-PIN-3
  pin4 := gpio.Pin RMT-PIN-4

  // Just test that we can allocate 4 different rmt resources.

  rmt1 := rmt.Channel pin1 --input
  rmt2 := rmt.Channel pin2 --input
  rmt3 := rmt.Channel pin3 --output
  rmt4 := rmt.Channel pin4 --output

  rmt1.close
  rmt2.close
  rmt3.close
  rmt4.close

  pin1.close
  pin2.close
  pin3.close
  pin4.close

  print "all tests done"
