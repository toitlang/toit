// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import io.stdio
import .network-binary as binary

// Exercise a receive timeout after binary traffic, using the current adapter.
main:
  print "RP2040 recovery exception: READY"
  if stdio.stdin.read-line != "fail": throw "UNEXPECTED_RECOVERY_TEST_COMMAND"
  print "RP2040 recovery exception: TRIGGERED"
  error := catch: binary.run --receive-timeout
  if error != "DEADLINE_EXCEEDED": throw "UNEXPECTED_MODEM_RECOVERY_RESULT: $error"
  print "RP2040 modem recovery: DEADLINE_EXCEEDED"
  throw "USB_RECOVERY_AFTER_MODEM_TIMEOUT"
