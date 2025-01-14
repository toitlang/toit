// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests the pulse_counter library.

For the setup see the comment near $Variant.pulse-counter1-in1.
*/

import expect show *
import gpio
import pulse-counter
import rmt

import .test
import .variants

IN1 /int ::= Variant.CURRENT.pulse-counter1-in1
OUT1 /int := Variant.CURRENT.pulse-counter1-out1

IN2 /int ::= Variant.CURRENT.pulse-counter1-in2
OUT2 /int := Variant.CURRENT.pulse-counter1-out2

CHANNEL-COUNT ::= Variant.CURRENT.pulse-counter-channel-count

main:
  run-test: test

test:
  in := gpio.Pin IN1
  out := gpio.Pin OUT1 --output

  unit := pulse-counter.Unit

  // TODO(florian): we would like to check that the unit's value is 0.
  // However, in ESP-IDF 4.3/4.4, the unit isn't allocated yet, and we are not allowed to
  // read the value yet.
  // expect_equals 0 unit.value

  /** ---- Count when edge raises. ---- */
  channel := unit.add-channel in
  expect-equals 0 unit.value

  out.set 1
  expect-equals 1 unit.value
  out.set 0
  expect-equals 1 unit.value

  /** ---- Second channel affects the same unit. ---- */
  in2 := gpio.Pin IN2
  out2 := gpio.Pin OUT2 --output

  channel2 := unit.add-channel in2

  expect-equals 1 unit.value
  out2.set 1
  expect-equals 2 unit.value
  out2.set 0

  /** ---- It is possible to remove a channel and add another one. ---- */
  channel.close
  channel2.close

  channel = unit.add-channel in
  channel2 = unit.add-channel in2

  expect-equals 2 unit.value

  out.set 1
  out2.set 1
  expect-equals 4 unit.value

  out.set 0
  out2.set 0

  unit.close

  /** ---- Use all 4/8 units, each with 2 channels. ---- */
  units := List CHANNEL-COUNT: unit = pulse-counter.Unit
  units.do:
    it.add-channel in
    it.add-channel in2

  units.do: expect-equals 0 it.value

  out.set 1
  out2.set 1

  units.do: expect-equals 2 it.value

  out.set 0
  out2.set 0

  units.do: it.close

  /** ---- Do it again, showing that the values a reset and that we properly release the resources. ---- */

  units = List CHANNEL-COUNT: unit = pulse-counter.Unit
  units.do:
    it.add-channel in
    it.add-channel in2

  units.do: expect-equals 0 it.value

  out.set 1
  out2.set 1

  units.do: expect-equals 2 it.value

  out.set 0
  out2.set 0

  units.do: it.close

  /** ---- Test the counting modes. ---- */

  unit = pulse-counter.Unit

  channel = unit.add-channel in --on-positive-edge=pulse-counter.Unit.DO-NOTHING --on-negative-edge=pulse-counter.Unit.DO-NOTHING
  expect-equals 0 unit.value
  out.set 1
  expect-equals 0 unit.value
  out.set 0
  expect-equals 0 unit.value
  channel.close

  channel = unit.add-channel in --on-positive-edge=pulse-counter.Unit.DECREMENT --on-negative-edge=pulse-counter.Unit.INCREMENT
  expect-equals 0 unit.value
  out.set 1
  expect-equals -1 unit.value
  out.set 0
  expect-equals 0 unit.value
  channel.close

  channel = unit.add-channel in --on-positive-edge=pulse-counter.Unit.INCREMENT --on-negative-edge=pulse-counter.Unit.DECREMENT
  expect-equals 0 unit.value
  out.set 1
  expect-equals 1 unit.value
  out.set 0
  expect-equals 0 unit.value
  channel.close

  /** ---- Test the control modes. ---- */
  channel = unit.add-channel in --on-positive-edge=pulse-counter.Unit.INCREMENT --on-negative-edge=pulse-counter.Unit.DECREMENT \
      --control-pin=in2 --when-control-low=pulse-counter.Unit.KEEP --when-control-high=pulse-counter.Unit.KEEP

  out2.set 0
  expect-equals 0 unit.value
  out.set 1
  expect-equals 1 unit.value
  out.set 0
  expect-equals 0 unit.value

  out2.set 1
  expect-equals 0 unit.value
  out.set 1
  expect-equals 1 unit.value
  out.set 0
  expect-equals 0 unit.value

  out2.set 0
  channel.close

  channel = unit.add-channel in --on-positive-edge=pulse-counter.Unit.INCREMENT --on-negative-edge=pulse-counter.Unit.DECREMENT \
      --control-pin=in2 --when-control-low=pulse-counter.Unit.DISABLE --when-control-high=pulse-counter.Unit.REVERSE

  out2.set 0
  expect-equals 0 unit.value
  out.set 1
  expect-equals 0 unit.value
  out.set 0
  expect-equals 0 unit.value

  out2.set 1
  expect-equals 0 unit.value
  out.set 1
  expect-equals -1 unit.value
  out.set 0
  expect-equals 0 unit.value

  out2.set 0
  channel.close

  channel = unit.add-channel in --on-positive-edge=pulse-counter.Unit.INCREMENT --on-negative-edge=pulse-counter.Unit.DECREMENT \
      --control-pin=in2 --when-control-low=pulse-counter.Unit.REVERSE --when-control-high=pulse-counter.Unit.DISABLE

  out2.set 0
  expect-equals 0 unit.value
  out.set 1
  expect-equals -1 unit.value
  out.set 0
  expect-equals 0 unit.value

  out2.set 1
  expect-equals 0 unit.value
  out.set 1
  expect-equals 0 unit.value
  out.set 0
  expect-equals 0 unit.value

  out2.set 0
  channel.close
  unit.close

  /** ---- Test the clear function. ---- */
  unit = pulse-counter.Unit
  channel = unit.add-channel in
  expect-equals 0 unit.value

  out.set 1
  expect-equals 1 unit.value
  out.set 0
  expect-equals 1 unit.value
  out.set 1
  expect-equals 2 unit.value
  out.set 0
  expect-equals 2 unit.value

  unit.clear
  expect-equals 0 unit.value
  out.set 1
  expect-equals 1 unit.value
  out.set 0
  expect-equals 1 unit.value

  unit.close

  /** ---- Test the start/stop functions. ---- */
  unit = pulse-counter.Unit
  channel = unit.add-channel in
  expect-equals 0 unit.value

  out.set 1
  expect-equals 1 unit.value
  out.set 0
  expect-equals 1 unit.value
  out.set 1
  expect-equals 2 unit.value
  out.set 0
  expect-equals 2 unit.value

  unit.stop

  out.set 1
  expect-equals 2 unit.value
  out.set 0
  expect-equals 2 unit.value

  unit.stop  // Should be idempotent.

  out.set 1
  expect-equals 2 unit.value
  out.set 0
  expect-equals 2 unit.value

  unit.start

  out.set 1
  expect-equals 3 unit.value
  out.set 0
  expect-equals 3 unit.value

  unit.start  // Should be idempotent.

  out.set 1
  expect-equals 4 unit.value
  out.set 0
  expect-equals 4 unit.value

  unit.close
  /** ---- Test the min and max values. ---- */
  unit = pulse-counter.Unit --low=-15 --high=17
  channel = unit.add-channel in --on-positive-edge=pulse-counter.Unit.INCREMENT --on-negative-edge=pulse-counter.Unit.INCREMENT \
      --control-pin=in2 --when-control-low=pulse-counter.Unit.KEEP --when-control-high=pulse-counter.Unit.REVERSE

  // Increment.
  out2.set 0
  expect-equals 0 unit.value

  10.repeat:
    out.set 1
    out.set 0
  expect-equals 3 unit.value  // 20 % 17.

  unit.clear

  // Decrement.
  out2.set 1

  10.repeat:
    out.set 1
    out.set 0
  expect-equals -5 unit.value  // -20 % 15.

  unit.close

  /** ---- Test the glitch filter. ---- */
  out.close

  out = gpio.Pin OUT1
  rmt-channel := rmt.Channel --output out --clk-div=1 --idle-level=0

  // Since the RMT also runs on the ABP clock, we can't produce any pulse that is shorter than 12.5ns.
  // Therefore set the glitch filter to 25ns. This should make it possible to drop the shortest pulses
  // the RMT can produce.
  unit = pulse-counter.Unit --glitch-filter-ns=45
  unit.add-channel in --on-negative-edge=pulse-counter.Unit.INCREMENT

  expect-equals 0 unit.value

  shortest-pulse := rmt.Signals 2
  shortest-pulse.set 0 --level=1 --period=1
  shortest-pulse.set 1 --level=0 --period=0
  rmt-channel.write shortest-pulse

  expect-equals 0 unit.value

  // If the pulse is 3 ticks long, then the pulse counter should detect it.
  // If we use a resistor than the rise/fall time of the signal might not make
  // it fast enough. -> Use 4 ticks.
  short-pulse := rmt.Signals 2
  shortest-pulse.set 0 --level=1 --period=4
  shortest-pulse.set 1 --level=0 --period=0
  rmt-channel.write shortest-pulse

  expect-equals 2 unit.value  // Up and down.

  unit.close
