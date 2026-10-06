// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .session
import ..paired.ble as ble-tests

main:
  session := Session
  try:
    ble-tests.run session
    session.finish
  finally:
    session.close
