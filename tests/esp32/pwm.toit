// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests the LEDC (pwm) library.

Setup:
Connect pin 18 and 19 with a 330 Ohm resistor. The resistor isn't
  strictly necessary but can prevent accidental short circuiting.

Similarly, connect pin 26 to pin 33 with a 330 Ohm resistor.
*/

import expect show *
import gpio
import pulse-counter
import gpio.pwm

IN1 /int ::= 18
IN2 /int ::= 33

OUT1 /int := 19
OUT2 /int := 26

main:
  // Run several times to make sure we release the resources correctly.
  10.repeat:
    in1 := gpio.Pin IN1
    out1 := gpio.Pin OUT1
    in2 := gpio.Pin IN2
    out2 := gpio.Pin OUT2

    pulse-unit1 := pulse-counter.Unit
    pulse-channel1 := pulse-unit1.add-channel in1

    expect-equals 0 pulse-unit1.value

    generator := pwm.Pwm --frequency=1000
    start-us := Time.monotonic-us
    pwm-channel1 := generator.start out1 --duty-factor=0.5
    sleep --ms=1
    pwm-channel1.set-duty-factor 0.5

    sleep --ms=1_500

    // Disable the pwm by setting the duty factor to 0.
    pwm-channel1.set-duty-factor 0.0
    stop-us := Time.monotonic-us
    diff-in-ms := (stop-us - start-us) / 1000

    unit-value1 := pulse-unit1.value
    expect (0.8 * diff-in-ms) < unit-value1 < (1.2 * diff-in-ms)
    sleep --ms=3

    // Expect that the pwm is stopped:
    expect-equals unit-value1 pulse-unit1.value

    // TODO(florian): why do we see transitions to 0?
    // pwm_channel1.set_duty_factor 1.0

    // sleep --ms=5

    // // We should see one transition (from 0 to 1).
    // expect_equals (unit_value1 + 1) pulse_unit1.value

    pwm-channel1.close
    // At this point the pin is floating.
    // Change it to pull-down to avoid accidental counting.
    in1.configure --input --pull-down

    unit-value1 = pulse-unit1.value

    pulse-unit2 := pulse-counter.Unit
    pulse-channel2 := pulse-unit2.add-channel in2

    expect-equals 0 pulse-unit2.value

    start-us = Time.monotonic-us
    pwm-channel2 := generator.start out2 --duty-factor=0.5

    sleep --ms=15

    // Disable the pwm by setting the duty factor to 0.
    pwm-channel2.set-duty-factor 0.0
    stop-us = Time.monotonic-us
    diff-in-ms = (stop-us - start-us) / 1000
    unit-value2 := pulse-unit2.value

    expect (0.8 * diff-in-ms) < unit-value2 < (1.2 * diff-in-ms)

    sleep --ms=3
    // Expect that the pwm is stopped:
    expect-equals unit-value2 pulse-unit2.value

    // Make sure pin1 is unchanged.

    expect-equals unit-value1 pulse-unit1.value

    generator.close
    in1.close
    out1.close
    in2.close
    out2.close
    pulse-unit1.close
    pulse-unit2.close

  print "all tests done"
