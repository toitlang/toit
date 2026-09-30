// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license in lib/LICENSE.
import expect show *
import rp2350.pio
import .programs

main:
  expect-equals 3 ECHO-PROGRAM.size
  expect-equals 2 CAPTURE-PROGRAM.size
  expect-equals 1 OUTPUT-BITS-PROGRAM.size
  expect-throw "OUT_OF_RANGE": pio.Program []
  expect-throw "OUT_OF_RANGE": pio.Program [0xa042] --wrap=1
  expect-throw "INVALID_ARGUMENT": pio.Program [0x0001]
  expect-throw "OUT_OF_RANGE": pio.Program [0xa042] --push-threshold=0
  expect-throw "OUT_OF_RANGE": pio.Program [0xa042] --side-count=5 --side-optional
