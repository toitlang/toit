// Copyright (C) 2025 Toitware ApS.
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

main:
  run-test: test-basics

test
    --in/i2s.Bus
    --out/i2s.Bus
    --preload/bool
    --bits-per-sample/int
    --generator/DataGenerator
    --start-in-first/bool
    --expect-0s/bool=false
    --expect-missing/bool=false:

  if preload:
    while true:
      chunk-preload := generator.do: out.preload it
      if chunk-preload == 0: break

    expect generator.written > 0
    print "Preloaded $generator.written bytes"


  in-started := monitor.Latch
  out-started := monitor.Latch

  done := false
  task::
    if not start-in-first: out-started.get
    in.start
    in-started.set true
    while true:
      chunk := in.read
      if in.errors != 0: print "Errors: $in.errors"
      generator.verify chunk
      if generator.verified > 10 * 1024:
        done = true
        break
    expect-equals 0 in.errors

  if start-in-first: in-started.get
  if in != out: out.start
  out-started.set true

  while not done:
    if out.errors != 0:
      print "Out errors: $out.errors"
      break
    written := generator.do: out.write it
  print "Wrote $generator.written in total"
  expect-equals 0 out.errors

test-basics:
  data1 := gpio.Pin DATA1
  data2 := gpio.Pin DATA2
  clk1 := gpio.Pin CLK1
  clk2 := gpio.Pin CLK2
  ws1 := gpio.Pin WS1
  ws2 := gpio.Pin WS2

  [32, 16].do: | sample-size |
    print "Sample size: $sample-size"

    out/i2s.Bus? := null
    in/i2s.Bus? := null
    generator/DataGenerator? := null

    // See https://github.com/espressif/esp-idf/issues/15275.
    if sample-size != 32 or system.architecture != system.ARCHITECTURE-ESP32:
      // Without preload.
      out = i2s.Bus
          --master=false
          --tx=data1
          --sck=clk1
          --ws=ws1
      out.configure
          --sample-rate=SAMPLE_RATE
          --bits-per-sample=sample-size

      in = i2s.Bus
          --master
          --rx=data2
          --sck=clk2
          --ws=ws2
      in.configure
          --sample-rate=SAMPLE_RATE
          --bits-per-sample=sample-size

      generator = VerifyingDataGenerator sample-size
          --needs-synchronization

      test
          --start-in-first=false
          --in=in
          --out=out
          --preload=false
          --bits-per-sample=sample-size
          --generator=generator

      out.close
      in.close

      out = i2s.Bus
          --master=false
          --tx=data1
          --sck=clk1
          --ws=ws1
      out.configure
          --sample-rate=SAMPLE_RATE
          --bits-per-sample=sample-size

      in = i2s.Bus
          --master
          --rx=data2
          --sck=clk2
          --ws=ws2
      in.configure
          --sample-rate=SAMPLE_RATE
          --bits-per-sample=sample-size

      generator = VerifyingDataGenerator sample-size
          --allow-leading-0-samples
          --needs-synchronization=(sample-size == 32)

      test
          --start-in-first=false
          --in=in
          --out=out
          --preload=true
          --bits-per-sample=sample-size
          --generator=generator

      out.close
      in.close

    // Same but switch master.
    out = i2s.Bus
        --master
        --tx=data1
        --sck=clk1
        --ws=ws1
    out.configure
        --sample-rate=SAMPLE_RATE
        --bits-per-sample=sample-size

    in = i2s.Bus
        --master=false
        --rx=data2
        --sck=clk2
        --ws=ws2
    in.configure
        --sample-rate=SAMPLE_RATE
        --bits-per-sample=sample-size

    generator = VerifyingDataGenerator sample-size
        --allow-missing-first-samples

    test
        --start-in-first=true
        --expect-missing
        --in=in
        --out=out
        --preload=true
        --bits-per-sample=sample-size
        --generator=generator

    out.close
    in.close

    // Share the same controller.
    in_out := i2s.Bus
        --master=true
        --tx=data1
        --rx=data2
        --sck=clk1
        --ws=ws1
    in_out.configure
        --sample-rate=SAMPLE_RATE
        --bits-per-sample=sample-size

    generator = VerifyingDataGenerator sample-size
        --allow-missing-first-samples

    test
        --start-in-first=true
        --in=in_out
        --out=in_out
        --preload=true
        --bits-per-sample=sample-size
        --generator=generator

    in_out.close

    // Without preload.
    in_out = i2s.Bus
        --master=true
        --tx=data1
        --rx=data2
        --sck=clk1
        --ws=ws1
    in_out.configure
        --sample-rate=SAMPLE_RATE
        --bits-per-sample=sample-size

    generator = VerifyingDataGenerator sample-size
        --needs-synchronization

    test
        --start-in-first=true
        --in=in_out
        --out=in_out
        --preload=false
        --bits-per-sample=sample-size
        --generator=generator

    in_out.stop

    // Reconfigure.
    in_out.configure
        --sample-rate=SAMPLE-RATE * 2
        --bits-per-sample=sample-size

    generator = VerifyingDataGenerator sample-size
        --needs-synchronization

    test
        --start-in-first=true
        --in=in_out
        --out=in_out
        --preload=false
        --bits-per-sample=sample-size
        --generator=generator

    in_out.close
