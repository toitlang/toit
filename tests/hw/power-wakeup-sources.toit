// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
import expect show *
import gpio
import system.power

// Use a free wake GPIO: nRF P1.00=32, original ESP32 GPIO33=33, EC618 PAD42=42.
// Run in isolation: this test intentionally replaces the configuration of PIN.
PIN ::= 32

main:
  // Inspection/configuration must not take ownership from a live GPIO.
  pin := gpio.Pin PIN --input --pull-down
  try:
    power.configure-wakeup-pin PIN --pull-down
    before := configured
    expect-equals true before.wake-high
    expect-equals true before.pull-down
    expect (before.trigger == power.WAKE-LEVEL or before.trigger == power.WAKE-EDGE)
    power.configure-wakeup-pin PIN --trigger=before.trigger --pull-down
    expect-equals before.trigger configured.trigger
    other-mode := before.trigger == power.WAKE-LEVEL ? power.WAKE-EDGE : power.WAKE-LEVEL
    // The current supported boards each implement only one deep-sleep trigger mode.
    expect-throw "UNSUPPORTED": power.configure-wakeup-pin PIN --trigger=other-mode
    expect-equals before.trigger configured.trigger
    expect-equals true configured.wake-high
    expect-equals true configured.pull-down
    expect-throw "INVALID_ARGUMENT": power.configure-wakeup-pin PIN --pull-up --pull-down
    expect-equals true configured.pull-down

    power.configure-wakeup-pin PIN --no-wake-high --pull-up
    expect-equals false configured.wake-high
    expect-equals true configured.pull-up
    expect-equals false configured.pull-down
    expect-equals true before.wake-high
    before.pins.clear
    expect-list-equals [PIN] configured.pins
    power.disable-wakeup-pin PIN
    expect-equals null configured
    print "WAKE CONFIGURATION SNAPSHOT PASS"
  finally:
    power.disable-wakeup-pin PIN
    pin.close

configured -> power.PinWakeup?:
  power.wakeup-sources.do: |source|
    if source is power.PinWakeup and source.pins.contains PIN: return source
  return null
