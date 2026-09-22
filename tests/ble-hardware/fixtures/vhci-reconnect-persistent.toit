// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.esp32
import .hci-server as fixture

// Twenty connections share one controller/host; each gets a fresh GATT session.
main:
  if (fixture.run (esp32.Esp32Transport) --cycles=20 --expected-count=10) != 200:
    throw "RECONNECT_TOTAL_MISMATCH"
