// Copyright (C) 2025 Toit contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests the i2s peripheral.

For the setup see the documentation near $Variant.i2s-data1.
*/

import expect show *
import gpio
import i2s
import monitor
import system

import .i2s-utils
import .test
import .variants

DATA1 ::= Variant.CURRENT.i2s-data1
DATA2 ::= Variant.CURRENT.i2s-data2

CLK1 ::= Variant.CURRENT.i2s-clk1
CLK2 ::= Variant.CURRENT.i2s-clk2

WS1 ::= Variant.CURRENT.i2s-ws1
WS2 ::= Variant.CURRENT.i2s-ws2

SAMPLE_RATE ::= 10000
SAMPLE_SIZE ::= 16
FORMAT ::= i2s.Bus.FORMAT-PCM-SHORT


main:
  run-test: test

test:
  data1 := gpio.Pin DATA1
  data2 := gpio.Pin DATA2
  clk1 := gpio.Pin CLK1
  clk2 := gpio.Pin CLK2
  ws1 := gpio.Pin WS1
  ws2 := gpio.Pin WS2

  out := i2s.Bus
      --master=false
      --tx=data1
      --sck=clk1
      --ws=ws1
  out.configure
      --sample-rate=SAMPLE_RATE
      --bits-per-sample=SAMPLE-SIZE
      --format=FORMAT

  in := i2s.Bus
      --master
      --rx=data2
      --sck=clk2
      --ws=ws2
  in.configure
      --sample-rate=SAMPLE_RATE
      --bits-per-sample=SAMPLE-SIZE
      --format=FORMAT

  should-read := true
  task::
    while should-read:
      in.read
      yield

  out.start
  in.start

  while out.errors == 0:
    sleep --ms=10

  print "Errors: $out.errors"
  print "Overrun errors: $(out.errors --overrun)"
  print "Underrun errors: $(out.errors --underrun)"
  expect out.errors > 0
  expect ((out.errors --underrun) > 0)
  expect-equals 0 (out.errors --overrun)
  out.write #[0x01, 0x02]

  // We want to get more errors.
  // We don't want to see more console errors.
  errors := out.errors
  while errors == out.errors:
    sleep --ms=10
  out.write #[0x01, 0x02]

  expect-equals 0 in.errors
  should-read = false

  while in.errors == 0:
    sleep --ms=10

  print "Errors: $in.errors"
  print "Overrun errors: $(out.errors --overrun)"
  print "Underrun errors: $(out.errors --underrun)"
  expect in.errors > 0
  expect ((in.errors --overrun) > 0)
  expect-equals 0 (in.errors --underrun)

  // We should get a warning/error message now.
  in.read

  errors = in.errors
  while errors == in.errors:
    sleep --ms=10

  // Now we shouldn't see any error.
  in.read

  out.stop
  in.stop
