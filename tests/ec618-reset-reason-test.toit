// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
import expect show *
import ec618
import system.power

main:
  expect-equals 0 ec618.RESET-UNKNOWN
  expect-equals power.RESET-POWER-ON ec618.RESET-POWER-ON
  expect-equals power.RESET-SOFTWARE ec618.RESET-SOFTWARE
  expect-equals power.RESET-BROWNOUT ec618.RESET-BROWNOUT
  expect-equals power.RESET-WATCHDOG ec618.RESET-WATCHDOG
  expect-equals power.RESET-LOW-POWER-WAKE ec618.RESET-LOW-POWER-WAKE
  expect-equals power.RESET-CPU-LOCKUP ec618.RESET-CPU-LOCKUP
  expect-equals power.RESET-HARDWARE ec618.RESET-HARDWARE
  expect-equals power.RESET-TEMPERATURE ec618.RESET-TEMPERATURE
  expect-equals "unknown" (ec618.reset-reason-name 0)
  expect-equals "power-on" (ec618.reset-reason-name ec618.RESET-POWER-ON)
  expect-equals "low-power-wake" (ec618.reset-reason-name ec618.RESET-LOW-POWER-WAKE)
  expect-equals "hardware" (ec618.reset-reason-name ec618.RESET-HARDWARE)
  expect-equals "watchdog" (ec618.reset-reason-name ec618.RESET-WATCHDOG)
  expect-equals "software,watchdog"
      ec618.reset-reason-name (ec618.RESET-SOFTWARE | ec618.RESET-WATCHDOG)
  expect-equals "reset-1048576" (ec618.reset-reason-name (1 << 20))
  expect-equals "power-on,reset-1048576"
      ec618.reset-reason-name (ec618.RESET-POWER-ON | (1 << 20))
