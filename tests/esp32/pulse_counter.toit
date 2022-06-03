// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests the pulse_counter library.

Setup:
Connect pin 18 and 19 with a 330 Ohm resistor. The resistor isn't
  strictly necessary but can prevent accidental short circuiting.

Similarly, connect pin 25 to pin 26 with a 330 Ohm resistor.
*/

import expect show *
import gpio
import pulse_counter
import rmt

IN1 /int ::= 18
IN2 /int ::= 25

OUT1 /int := 19
OUT2 /int := 26

main:
  in := gpio.Pin IN1
  out := gpio.Pin OUT1 --output

  // TODO(florian): we would like to check that the unit's value is 0.
  // However, in ESP-IDF 4.3/4.4, the unit isn't allocated yet, and we are not allowed to
  // read the value yet.
  // expect_equals 0 unit.value

  /** ---- Count when edge raises. ---- */
  unit := pulse_counter.Unit
  channel := unit.add_channel in
  expect_equals 0 unit.value

  out.set 1
  expect_equals 1 unit.value
  out.set 0
  expect_equals 1 unit.value

  /** ---- Second channel affects the same unit. ---- */
  in2 := gpio.Pin IN2
  out2 := gpio.Pin OUT2 --output

  channel2 := unit.add_channel in2

  expect_equals 1 unit.value
  out2.set 1
  expect_equals 2 unit.value
  out2.set 0

  /** ---- It is possible to remove a channel and add another one. ---- */
  channel.close
  channel2.close

  channel = unit.add_channel in
  channel2 = unit.add_channel in2

  expect_equals 2 unit.value

  out.set 1
  out2.set 1
  expect_equals 4 unit.value

  out.set 0
  out2.set 0

  unit.close

  /** ---- Use all 8 units, each with 2 channels. ---- */
  // This requires an ESP32 with 8 units.
  units := List 8: unit = pulse_counter.Unit
  units.do:
    it.add_channel in
    it.add_channel in2

  units.do: expect_equals 0 it.value

  out.set 1
  out2.set 1

  units.do: expect_equals 2 it.value

  out.set 0
  out2.set 0

  units.do: it.close

  /** ---- Do it again, showing that the values a reset and that we properly release the resources. ---- */

  units = List 8: unit = pulse_counter.Unit
  units.do:
    it.add_channel in
    it.add_channel in2

  units.do: expect_equals 0 it.value

  out.set 1
  out2.set 1

  units.do: expect_equals 2 it.value

  out.set 0
  out2.set 0

  units.do: it.close

  /** ---- Test the counting modes. ---- */

  unit = pulse_counter.Unit

  channel = unit.add_channel in --on_positive_edge=pulse_counter.Unit.DO_NOTHING --on_negative_edge=pulse_counter.Unit.DO_NOTHING
  expect_equals 0 unit.value
  out.set 1
  expect_equals 0 unit.value
  out.set 0
  expect_equals 0 unit.value
  channel.close

  channel = unit.add_channel in --on_positive_edge=pulse_counter.Unit.DECREMENT --on_negative_edge=pulse_counter.Unit.INCREMENT
  expect_equals 0 unit.value
  out.set 1
  expect_equals -1 unit.value
  out.set 0
  expect_equals 0 unit.value
  channel.close

  channel = unit.add_channel in --on_positive_edge=pulse_counter.Unit.INCREMENT --on_negative_edge=pulse_counter.Unit.DECREMENT
  expect_equals 0 unit.value
  out.set 1
  expect_equals 1 unit.value
  out.set 0
  expect_equals 0 unit.value
  channel.close

  /** ---- Test the control modes. ---- */
  channel = unit.add_channel in --on_positive_edge=pulse_counter.Unit.INCREMENT --on_negative_edge=pulse_counter.Unit.DECREMENT \
      --control_pin=in2 --when_control_low=pulse_counter.Unit.KEEP --when_control_high=pulse_counter.Unit.KEEP

  out2.set 0
  expect_equals 0 unit.value
  out.set 1
  expect_equals 1 unit.value
  out.set 0
  expect_equals 0 unit.value

  out2.set 1
  expect_equals 0 unit.value
  out.set 1
  expect_equals 1 unit.value
  out.set 0
  expect_equals 0 unit.value

  out2.set 0
  channel.close

  channel = unit.add_channel in --on_positive_edge=pulse_counter.Unit.INCREMENT --on_negative_edge=pulse_counter.Unit.DECREMENT \
      --control_pin=in2 --when_control_low=pulse_counter.Unit.DISABLE --when_control_high=pulse_counter.Unit.REVERSE

  out2.set 0
  expect_equals 0 unit.value
  out.set 1
  expect_equals 0 unit.value
  out.set 0
  expect_equals 0 unit.value

  out2.set 1
  expect_equals 0 unit.value
  out.set 1
  expect_equals -1 unit.value
  out.set 0
  expect_equals 0 unit.value

  out2.set 0
  channel.close

  channel = unit.add_channel in --on_positive_edge=pulse_counter.Unit.INCREMENT --on_negative_edge=pulse_counter.Unit.DECREMENT \
      --control_pin=in2 --when_control_low=pulse_counter.Unit.REVERSE --when_control_high=pulse_counter.Unit.DISABLE

  out2.set 0
  expect_equals 0 unit.value
  out.set 1
  expect_equals -1 unit.value
  out.set 0
  expect_equals 0 unit.value

  out2.set 1
  expect_equals 0 unit.value
  out.set 1
  expect_equals 0 unit.value
  out.set 0
  expect_equals 0 unit.value

  out2.set 0
  channel.close
  unit.close

  /** ---- Test the clear function. ---- */
  unit = pulse_counter.Unit
  channel = unit.add_channel in
  expect_equals 0 unit.value

  out.set 1
  expect_equals 1 unit.value
  out.set 0
  expect_equals 1 unit.value
  out.set 1
  expect_equals 2 unit.value
  out.set 0
  expect_equals 2 unit.value

  unit.clear
  expect_equals 0 unit.value
  out.set 1
  expect_equals 1 unit.value
  out.set 0
  expect_equals 1 unit.value

  unit.close

  /** ---- Test the start/stop functions. ---- */
  unit = pulse_counter.Unit
  channel = unit.add_channel in
  expect_equals 0 unit.value

  out.set 1
  expect_equals 1 unit.value
  out.set 0
  expect_equals 1 unit.value
  out.set 1
  expect_equals 2 unit.value
  out.set 0
  expect_equals 2 unit.value

  unit.stop

  out.set 1
  expect_equals 2 unit.value
  out.set 0
  expect_equals 2 unit.value

  unit.stop  // Should be idempotent.

  out.set 1
  expect_equals 2 unit.value
  out.set 0
  expect_equals 2 unit.value

  unit.start

  out.set 1
  expect_equals 3 unit.value
  out.set 0
  expect_equals 3 unit.value

  unit.start  // Should be idempotent.

  out.set 1
  expect_equals 4 unit.value
  out.set 0
  expect_equals 4 unit.value

  unit.close
  /** ---- Test the min and max values. ---- */
  unit = pulse_counter.Unit --low=-15 --high=17
  channel = unit.add_channel in --on_positive_edge=pulse_counter.Unit.INCREMENT --on_negative_edge=pulse_counter.Unit.INCREMENT \
      --control_pin=in2 --when_control_low=pulse_counter.Unit.KEEP --when_control_high=pulse_counter.Unit.REVERSE

  // Increment.
  out2.set 0
  expect_equals 0 unit.value

  10.repeat:
    out.set 1
    out.set 0
  expect_equals 3 unit.value  // 20 % 17.

  unit.clear

  // Decrement.
  out2.set 1

  10.repeat:
    out.set 1
    out.set 0
  expect_equals -5 unit.value  // -20 % 15.

  unit.close

  /** ---- Test the glitch filter. ---- */
  out.close

  out = gpio.Pin OUT1
  rmt_channel := rmt.Channel --output out --clk_div=1 --idle_level=0

  // Since the RMT also runs on the ABP clock, we can't produce any pulse that is shorter than 12.5ns.
  // There set the glitch filter to 25ns. This should make it possible to drop the shortest pulses
  // the RMT can produce.
  unit = pulse_counter.Unit --glitch_filter_ns=45
  unit.add_channel in --on_negative_edge=pulse_counter.Unit.INCREMENT

  expect_equals 0 unit.value

  shortest_pulse := rmt.Signals 2
  shortest_pulse.set 0 --level=1 --period=1
  shortest_pulse.set 1 --level=0 --period=0
  rmt_channel.write shortest_pulse

  expect_equals 0 unit.value

  // If the pulse is 3 ticks long, then the pulse counter should detect it.
  short_pulse := rmt.Signals 2
  shortest_pulse.set 0 --level=1 --period=3
  shortest_pulse.set 1 --level=0 --period=0
  rmt_channel.write shortest_pulse

  expect_equals 2 unit.value  // Up and down.

  unit.close

  print "all tests done"
