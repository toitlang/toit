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
import gpio.pwm

IN1 /int ::= 18
IN2 /int ::= 25

OUT1 /int := 19
OUT2 /int := 26

main:
  // Run several times to make sure we release the resources correctly.
  10.repeat:
    in1 := gpio.Pin IN1
    out1 := gpio.Pin OUT1
    in2 := gpio.Pin IN2
    out2 := gpio.Pin OUT2

    pulse_unit1 := pulse_counter.Unit
    pulse_channel1 := pulse_unit1.add_channel in1

    expect_equals 0 pulse_unit1.value

    generator := pwm.Pwm --frequency=1000
    start_us := Time.monotonic_us
    pwm_channel1 := generator.start out1 --duty_factor=0.5
    sleep --ms=1
    pwm_channel1.set_duty_factor 0.5

    sleep --ms=1_500

    // Disable the pwm by setting the duty factor to 0.
    pwm_channel1.set_duty_factor 0.0
    stop_us := Time.monotonic_us
    diff_in_ms := (stop_us - start_us) / 1000

    unit_value1 := pulse_unit1.value
    expect (0.8 * diff_in_ms) < unit_value1 < (1.2 * diff_in_ms)
    sleep --ms=3

    // Expect that the pwm is stopped:
    expect_equals unit_value1 pulse_unit1.value

    // TODO(florian): why do we see transitions to 0?
    // pwm_channel1.set_duty_factor 1.0

    // sleep --ms=5

    // // We should see one transition (from 0 to 1).
    // expect_equals (unit_value1 + 1) pulse_unit1.value

    pwm_channel1.close
    // At this point the pin is floating.
    // Change it to pull-down to avoid accidental counting.
    in1.configure --input --pull_down

    unit_value1 = pulse_unit1.value

    pulse_unit2 := pulse_counter.Unit
    pulse_channel2 := pulse_unit2.add_channel in2

    expect_equals 0 pulse_unit2.value

    start_us = Time.monotonic_us
    pwm_channel2 := generator.start out2 --duty_factor=0.5

    sleep --ms=15

    // Disable the pwm by setting the duty factor to 0.
    pwm_channel2.set_duty_factor 0.0
    stop_us = Time.monotonic_us
    diff_in_ms = (stop_us - start_us) / 1000
    unit_value2 := pulse_unit2.value

    expect (0.8 * diff_in_ms) < unit_value2 < (1.2 * diff_in_ms)

    sleep --ms=3
    // Expect that the pwm is stopped:
    expect_equals unit_value2 pulse_unit2.value

    // Make sure pin1 is unchanged.

    expect_equals unit_value1 pulse_unit1.value

    generator.close
    in1.close
    out1.close
    in2.close
    out2.close
    pulse_unit1.close
    pulse_unit2.close

  print "all tests done"
