// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
import expect show *
import nrf5340
import system
import system.power

main:
  expect-equals 32 nrf5340.P1-00
  expect-equals 36 nrf5340.P1-04
  if system.platform == system.PLATFORM-FREERTOS or
      system.platform == system.PLATFORM-ZEPHYR: return
  expect (not power.supports-timed-deep-sleep)
  expect-throw "UNIMPLEMENTED": power.reset
  expect-throw "UNIMPLEMENTED": power.reset-reason
  expect-throw "UNIMPLEMENTED": power.deep-sleep
  expect-throw "UNIMPLEMENTED": power.deep-sleep (Duration --s=1)
  expect-throw "UNIMPLEMENTED": power.deep-sleep Duration.ZERO
  expect-throw "UNIMPLEMENTED": power.configure-wakeup-pin 0
  expect-throw "UNIMPLEMENTED": power.disable-wakeup-pin 0
