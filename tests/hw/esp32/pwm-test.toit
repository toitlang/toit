// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests the LEDC (pwm) library.

For the setup see the comment near $Variant.pwm-in1.
*/

import expect show *
import gpio
import pulse-counter
import gpio.pwm

import .test
import .variants

IN1 /int ::= Variant.CURRENT.pwm-in1
OUT1 /int ::= Variant.CURRENT.pwm-out1

IN2 /int ::= Variant.CURRENT.pwm-in2
OUT2 /int := Variant.CURRENT.pwm-out2

main:
  run-test: test

test:
  // Run several times to make sure we release the resources correctly.
  10.repeat:
    in1 := gpio.Pin IN1
    out1 := gpio.Pin OUT1
    in2 := gpio.Pin IN2
    out2 := gpio.Pin OUT2

    pulse-unit1 := pulse-counter.Unit in1

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

    pulse-unit2 := pulse-counter.Unit in2

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
