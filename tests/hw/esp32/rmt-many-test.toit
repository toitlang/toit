// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests a simple pulse from the RMT peripheral.

For the setup see the comment near $Variant.rmt-many-in1.
*/

import rmt
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
  // Just test that we can allocate 4 different rmt resources.
  // Each channel reserves and releases its own pin.

  rmt1 := rmt.In RMT-IN1 --resolution=RESOLUTION
  rmt2 := rmt.In RMT-IN2 --resolution=RESOLUTION
  rmt3 := rmt.Out RMT-OUT1 --resolution=RESOLUTION
  rmt4 := rmt.Out RMT-OUT2 --resolution=RESOLUTION

  rmt1.close
  rmt2.close
  rmt3.close
  rmt4.close
