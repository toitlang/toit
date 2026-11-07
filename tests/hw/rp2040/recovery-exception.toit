// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import io.stdio

// Wait for the observer before failing, so it captures the complete exit path.
main:
  print "RP2040 recovery exception: READY"
  if stdio.stdin.read-line != "fail": throw "UNEXPECTED_RECOVERY_TEST_COMMAND"
  print "RP2040 recovery exception: TRIGGERED"
  throw "USB_RECOVERY_TEST_FAILURE"
