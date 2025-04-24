// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests the pulse_counter library.

For the setup see the comment near $Variant.pulse-counter1-in1.
*/

import expect show *
import gpio
import pulse-counter show *
import rmt
import system

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
  in2 := gpio.Pin IN2
  out2 := gpio.Pin OUT2 --output

  unit := Unit in
  expect-equals 0 unit.value
  out.set 1
  expect-equals 1 unit.value
  out.set 0
  expect-equals 1 unit.value
  out.set 1
  expect-equals 2 unit.value
  out.set 0
  expect-equals 2 unit.value
  unit.close

  unit = Unit in2
  expect-equals 0 unit.value
  out2.set 1
  expect-equals 1 unit.value
  out2.set 0
  expect-equals 1 unit.value
  out2.set 1
  expect-equals 2 unit.value
  out2.set 0
  expect-equals 2 unit.value
  unit.close

  unit = Unit --channels=[
    Channel in,
    Channel in2,
  ]

  expect-equals 0 unit.value

  out.set 1
  expect-equals 1 unit.value
  out.set 0
  expect-equals 1 unit.value

  out2.set 1
  expect-equals 2 unit.value
  out2.set 0

  unit.close

  /** ---- Use all 4/8 units, each with 2 channels. ---- */
  units := List CHANNEL-COUNT:
    Unit --channels=[
      Channel in,
      Channel in2,
    ]

  units.do: expect-equals 0 it.value

  out.set 1
  out2.set 1

  units.do: expect-equals 2 it.value

  out.set 0
  out2.set 0

  units.do: it.close

  /** ---- Do it again, showing that the values a reset and that we properly release the resources. ---- */

  units = List CHANNEL-COUNT:
    Unit --channels= [
      Channel in,
      Channel in2,
    ]

  units.do: expect-equals 0 it.value

  out.set 1
  out2.set 1

  units.do: expect-equals 2 it.value

  out.set 0
  out2.set 0

  units.do: it.close

  /** ---- Test the counting modes. ---- */

  unit = Unit in
      --on-positive-edge=Channel.EDGE-HOLD
      --on-negative-edge=Channel.EDGE-HOLD
  expect-equals 0 unit.value
  out.set 1
  expect-equals 0 unit.value
  out.set 0
  expect-equals 0 unit.value
  unit.close

  unit = Unit in
      --on-positive-edge=Channel.EDGE-DECREMENT
      --on-negative-edge=Channel.EDGE-INCREMENT
  expect-equals 0 unit.value
  out.set 1
  expect-equals -1 unit.value
  out.set 0
  expect-equals 0 unit.value
  unit.close

  unit = Unit in
      --on-positive-edge=Channel.EDGE-INCREMENT
      --on-negative-edge=Channel.EDGE-DECREMENT
  expect-equals 0 unit.value
  out.set 1
  expect-equals 1 unit.value
  out.set 0
  expect-equals 0 unit.value
  unit.close

  /** ---- Test the control modes. ---- */
  unit = Unit in
      --on-positive-edge=Channel.EDGE-INCREMENT
      --on-negative-edge=Channel.EDGE-DECREMENT
      --control-pin=in2
      --when-control-low=Channel.CONTROL-KEEP
      --when-control-high=Channel.CONTROL-KEEP

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
  unit.close

  unit = Unit in
      --on-positive-edge=Channel.EDGE-INCREMENT
      --on-negative-edge=Channel.EDGE-DECREMENT
      --control-pin=in2
      --when-control-low=Channel.CONTROL-HOLD
      --when-control-high=Channel.CONTROL-INVERSE

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
  unit.close

  unit = Unit in
      --on-positive-edge=Channel.EDGE-INCREMENT
      --on-negative-edge=Channel.EDGE-DECREMENT
      --control-pin=in2
      --when-control-low=Channel.CONTROL-INVERSE
      --when-control-high=Channel.CONTROL-HOLD

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
  unit.close

  /** ---- Test the clear function. ---- */
  unit = Unit in
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
  unit = Unit in
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
  unit = Unit in
      --low=-15
      --high=17
      --on-positive-edge=Channel.EDGE-INCREMENT
      --on-negative-edge=Channel.EDGE-INCREMENT
      --control-pin=in2
      --when-control-low=Channel.CONTROL-KEEP
      --when-control-high=Channel.CONTROL-INVERSE

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

  clk-div/int := ?
  glitch-filter-ns/int := ?

  if system.architecture == system.ARCHITECTURE-ESP32:
    // Since the RMT also runs on the ABP clock, we can't produce any pulse that is shorter than 12.5ns.
    // Therefore set the glitch filter to 25ns. This should make it possible to drop the shortest pulses
    // the RMT can produce.
    clk-div = 1
    glitch-filter-ns = 45
  else:
    // For non ESP32 devices the datasheet requires:
    //  3 × T_apb_clk + 5 × T_rmt_sclk < period × T_clk_div
    // For rmt_sclk equal to APB (the default as of this writing) this means:
    //   that we can have at most 9 * 12.5ns = 112.5ns.
    // We set the clk-div to 9, and the period to 1.
    clk-div = 9
    glitch-filter-ns = 125

  rmt-channel := rmt.Out out --resolution=(80_000_000 / clk-div)

  unit = Unit in --glitch-filter-ns=glitch-filter-ns --on-negative-edge=Channel.EDGE-INCREMENT

  expect-equals 0 unit.value

  shortest-pulse := rmt.Signals 2
  shortest-pulse.set 0 --level=1 --period=1
  shortest-pulse.set 1 --level=0 --period=0
  rmt-channel.write shortest-pulse --done-level=0

  expect-equals 0 unit.value

  // If the pulse is 3 ticks long, then the pulse counter should detect it.
  // If we use a resistor than the rise/fall time of the signal might not make
  // it fast enough. -> Use 4 ticks.
  short-pulse := rmt.Signals 2
  shortest-pulse.set 0 --level=1 --period=4
  shortest-pulse.set 1 --level=0 --period=0
  rmt-channel.write shortest-pulse --done-level=0

  expect-equals 2 unit.value  // Up and down.

  unit.close
