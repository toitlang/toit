// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests a simple pulse from the RMT peripheral.

For the setup see the comment near $Variant.rmt-many-in1.
*/

import rmt
import gpio
import monitor
import expect show *

import .test
import .variants

RMT-IN1 ::= Variant.CURRENT.rmt-many-in1
RMT-OUT1 ::= Variant.CURRENT.rmt-many-out1

RMT-IN2 ::= Variant.CURRENT.rmt-many-in2
RMT-OUT2 ::= Variant.CURRENT.rmt-many-out2

main:
  run-test: test

test:
  pin1 := gpio.Pin RMT-IN1
  pin2 := gpio.Pin RMT-IN2
  pin3 := gpio.Pin RMT-OUT1
  pin4 := gpio.Pin RMT-OUT2

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
