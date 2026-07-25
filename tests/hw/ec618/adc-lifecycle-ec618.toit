// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio.adc show Adc

/**
EC618 ADC channel-resource lifecycle regression.

Both AIO channels may be open at once, but each channel has exactly one
  system-wide owner. Running with the argument `leak` exits with both channels
  open; a following normal run verifies that forced resource-group teardown
  deinitialized and released them.
*/

expect-throws expected/string [block] -> none:
  caught := catch: block.call
  if caught == null:
    throw "expected '$expected' to be thrown, nothing was"
  if caught is string and caught.contains expected: return
  throw "expected '$expected', got: $caught"

main args:
  adc0 := Adc.channel 0
  adc1 := Adc.channel 1

  if not args.is-empty and args[0] == "leak":
    print "adc-lifecycle: leaving both channels open for container-teardown coverage"
    return

  expect-throws "ALREADY_IN_USE":
    Adc.channel 0
  expect-throws "ALREADY_IN_USE":
    Adc.channel 1

  adc0.close
  adc1.close

  adc0 = Adc.channel 0
  adc1 = Adc.channel 1
  adc0.close
  adc1.close

  print "adc-lifecycle: PASS exclusivity, close, and reacquisition"
