// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio
import esp32
import uart

import .pin-hold1-shared
import .test

/**
See 'pin-hold1-shared.toit'.
*/

hold pin-number:
  #primitive.esp32.pin_hold_enable

unhold pin-number:
  #primitive.esp32.pin_hold_disable

enable-hold-deepsleep:
  #primitive.esp32.deep_sleep_pin_hold_enable

disable-hold-deepsleep:
  #primitive.esp32.deep_sleep_pin_hold_disable

main:
  run-test --background: test

test:
  port := uart.Port
      --rx=gpio.Pin PIN-IN
      --tx=gpio.Pin PIN-FREE-AND-UNUSED
      --baud-rate=115200

  test-steps := {
    "TEST-STEP-01": :: test-step1,
    "TEST-STEP-02a": :: test-step2 1,
    "TEST-STEP-02b": :: test-step2 0,
    "TEST-RESET": :: test-reset,
  }
  data := #[]
  while true:
    chunk := port.in.read
    data += chunk
    print "received: $chunk.to-string-non-throwing"
    str := data.to-string-non-throwing
    test-steps.do: | key value |
      if str.contains key:
        value.call

test-step1:
  pin-out := gpio.Pin PIN-OUT --output
  // Test that a pin-hold prevents any further changes.
  pin-out.set 1
  hold PIN-OUT
  10.repeat:
    pin-out.set 0
    sleep --ms=10
    pin-out.set 1
    sleep --ms=10
  pin-out.set 0
  unhold PIN-OUT
  pin-out.close

test-step2 requested-state/int:
  pin-out := gpio.Pin PIN-OUT --output
  // Test that a pin-hold with enabled-hold-deepsleep keeps the pin in
  // the requested state.
  pin-out.set requested-state
  hold PIN-OUT
  enable-hold-deepsleep
  esp32.deep-sleep (Duration --ms=300)

test-reset:
  // Reset the device.
  disable-hold-deepsleep
  unhold PIN-OUT
  esp32.deep-sleep Duration.ZERO
