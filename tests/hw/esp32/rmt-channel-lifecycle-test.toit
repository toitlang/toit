// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests mixed RMT channel allocation, recreation, and failure cleanup.

No external wiring is needed. The output channel never transmits.
*/

import rmt
import system
import expect show *

import .test
import .variants

RESOLUTION ::= 1_000_000

main:
  run-test:
    test-channels Variant.CURRENT.unconnected-pin1 Variant.CURRENT.unconnected-pin2
        --shared-memory-blocks=(system.architecture == system.ARCHITECTURE-ESP32 ? 8 : 0)

test-channels rx-pin/int tx-pin/int --shared-memory-blocks/int:
  [false, true].do: |rx-first|
    [false, true].do: |close-rx-first|
      3.repeat:
        input/rmt.In? := null
        output/rmt.Out? := null
        try:
          if rx-first:
            input = rmt.In rx-pin --resolution=RESOLUTION
            output = rmt.Out tx-pin --resolution=RESOLUTION
          else:
            output = rmt.Out tx-pin --resolution=RESOLUTION
            input = rmt.In rx-pin --resolution=RESOLUTION
          expect-throw "ALREADY_IN_USE": rmt.In rx-pin --resolution=RESOLUTION
          expect-throw "ALREADY_IN_USE": rmt.Out tx-pin --resolution=RESOLUTION
          // Recreate both channel kinds while the other keeps the group alive.
          if close-rx-first:
            input.close
            input.close
            input = rmt.In rx-pin --resolution=RESOLUTION
            output.close
            output.close
            output = rmt.Out tx-pin --resolution=RESOLUTION
          else:
            output.close
            output.close
            output = rmt.Out tx-pin --resolution=RESOLUTION
            input.close
            input.close
            input = rmt.In rx-pin --resolution=RESOLUTION
        finally:
          if close-rx-first:
            if input: input.close
            if output: output.close
          else:
            if output: output.close
            if input: input.close
      print "RMT-MIXED order=$rx-first close-order=$close-rx-first PASS"

  // Native invalid-configuration failure must release the reserved pin.
  expect-constructor-failure: rmt.In rx-pin --resolution=0
  input := rmt.In rx-pin --resolution=RESOLUTION
  input.close
  expect-constructor-failure: rmt.Out tx-pin --resolution=0
  output := rmt.Out tx-pin --resolution=RESOLUTION
  output.close

  // Other variants have separate RX/TX pools, so one channel cannot exhaust both.
  if shared-memory-blocks == 0: return

  // Exhaust shared memory through each direction, using the other pin for failure.
  input = rmt.In rx-pin --resolution=RESOLUTION --memory-blocks=shared-memory-blocks
  try:
    expect-throw "ALREADY_IN_USE": rmt.Out tx-pin --resolution=RESOLUTION
  finally:
    input.close
  output = rmt.Out tx-pin --resolution=RESOLUTION
  input = rmt.In rx-pin --resolution=RESOLUTION
  input.close
  output.close

  output = rmt.Out tx-pin --resolution=RESOLUTION --memory-blocks=shared-memory-blocks
  try:
    expect-throw "ALREADY_IN_USE": rmt.In rx-pin --resolution=RESOLUTION
  finally:
    output.close
  input = rmt.In rx-pin --resolution=RESOLUTION
  output = rmt.Out tx-pin --resolution=RESOLUTION
  output.close
  input.close
  print "RMT-MIXED invalid-config/exhaustion/recovery PASS"

expect-constructor-failure [construct]:
  channel := null
  error := catch: channel = construct.call
  if channel: channel.close
  expect-equals "ESP_ERR_INVALID_ARG" error
