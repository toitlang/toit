// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system.firmware

/**
Validates the currently booted EC618 trial (rig utility, not a standalone OTA).

The utility fails when the running image is not awaiting validation.
*/

main:
  check_ firmware.is-validation-pending "the running firmware is not a trial"
  check_ firmware.validate "trial validation failed"
  check_ (not firmware.is-validation-pending) "validation remained pending"
  print "firmware-validate: trial promoted"

check_ condition/bool message/string -> none:
  if not condition: throw message
