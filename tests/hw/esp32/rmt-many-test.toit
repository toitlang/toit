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

RESOLUTION ::= 1_000_000  // 1MHz.

main:
  run-test: test

test:
  pin1 := gpio.Pin RMT-IN1
  pin2 := gpio.Pin RMT-IN2
  pin3 := gpio.Pin RMT-OUT1
  pin4 := gpio.Pin RMT-OUT2

  // Just test that we can allocate 4 different rmt resources.

  rmt1 := rmt.In pin1 --resolution=RESOLUTION
  rmt2 := rmt.In pin2 --resolution=RESOLUTION
  rmt3 := rmt.Out pin3 --resolution=RESOLUTION
  rmt4 := rmt.Out pin4 --resolution=RESOLUTION

  rmt1.close
  rmt2.close
  rmt3.close
  rmt4.close

  pin1.close
  pin2.close
  pin3.close
  pin4.close
