// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
import expect show *
import nrf5340
import system
import system.power

main:
  expect-equals 32 nrf5340.P1-00
  expect-equals 36 nrf5340.P1-04
  [Duration.ZERO, Duration --us=-1, Duration --ms=-1].do: |duration|
    expect-throw "INVALID_ARGUMENT": power.deep-sleep duration
  expect-throw "INVALID_ARGUMENT": power.configure-wakeup-pin -1
  expect-throw "INVALID_ARGUMENT": power.configure-wakeup-pin 0 --pull-up --pull-down
  expect-throw "INVALID_ARGUMENT": power.disable-wakeup-pin -1
  [-1, 3, int.MAX].do: |trigger|
    expect-throw "INVALID_ARGUMENT": power.configure-wakeup-pin 0 --trigger=trigger
  if system.platform == system.PLATFORM-FREERTOS or
      system.platform == system.PLATFORM-ZEPHYR: return
  expect (not power.supports-timed-deep-sleep)
  expect-throw "UNIMPLEMENTED": power.reset
  expect-throw "UNIMPLEMENTED": power.reset-reason
  expect-throw "UNIMPLEMENTED": power.wakeup-sources
  expect-throw "UNIMPLEMENTED": power.deep-sleep
  expect-throw "UNIMPLEMENTED": power.deep-sleep (Duration --s=1)
  // Positive sub-millisecond durations reach the platform-specific checks.
  expect-throw "UNIMPLEMENTED": power.deep-sleep (Duration --us=1)
  [power.WAKE-AUTO, power.WAKE-LEVEL, power.WAKE-EDGE].do: |trigger|
    expect-throw "UNIMPLEMENTED": power.configure-wakeup-pin 0 --trigger=trigger
  expect-throw "UNIMPLEMENTED": power.disable-wakeup-pin 0
