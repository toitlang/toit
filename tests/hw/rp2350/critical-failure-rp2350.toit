// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import expect show *
import system.firmware

main:
  expect firmware.is-validation-pending
  print "critical-failure-rp2350: rejecting trial before validation"
  expect-equals "healthy startup" "deliberate critical failure"
