// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
import expect show *
import ec618

main:
  // Preserve the original enum values and names independently of system.power.
  reasons := [
    ec618.RESET-POWER-ON, ec618.RESET-NORMAL, ec618.RESET-SOFTWARE,
    ec618.RESET-HARDFAULT, ec618.RESET-ASSERT, ec618.RESET-WATCHDOG-SOFTWARE,
    ec618.RESET-WATCHDOG-HARDWARE, ec618.RESET-LOCKUP, ec618.RESET-AON-WATCHDOG,
    ec618.RESET-BATTERY-LOW, ec618.RESET-TEMPERATURE-HIGH, ec618.RESET-FOTA,
    ec618.RESET-CP-RESET, ec618.RESET-UNKNOWN,
  ]
  names := [
    "power-on", "normal", "software", "hardfault", "assert", "watchdog-software",
    "watchdog-hardware", "lockup", "aon-watchdog", "battery-low",
    "temperature-high", "fota", "cp-reset", "unknown",
  ]
  reasons.size.repeat: |index|
    expect-equals index reasons[index]
    expect-equals names[index] (ec618.reset-reason-name reasons[index])
  expect-equals "reset-14" (ec618.reset-reason-name 14)
  expect-equals "reset--1" (ec618.reset-reason-name -1)
