// Copyright (C) 2026 Toit contributors.

// The container of the firmware installed over the air (hwota.toit):
// validates the new firmware and reports.

import system
import system.firmware

main:
  pending := firmware.is-validation-pending
  validated := pending and firmware.validate
  print "SUITE ota new firmware runs ($(system.platform) $(system.architecture)), pending $pending validated $validated"
  print "SUITE done"
