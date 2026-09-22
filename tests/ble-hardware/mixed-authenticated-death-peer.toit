// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.bond-flash
import .mixed-provider-pending-peer as fixture
import .mixed-resume-state as saved

main:
  state := saved.State (bond-flash.FlashRecords "toit.test/ble-mixed-resume-001-peer")
      [saved.S3]
      "PEER"
      --resume-only
  try:
    with-timeout --ms=160_000: fixture.run --state=state
  finally:
    state.close
