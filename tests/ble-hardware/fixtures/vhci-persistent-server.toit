// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.esp32
import .hci-server as fixture

// Separate service identity isolates this pair from Android and the echo soak.
SERVICE-ID ::= "9f6c1200-8e2a-4b13-9e97-94f353eeb001"

main:
  if (fixture.run (esp32.Esp32Transport) --cycles=20 --expected-count=10
      --service-id=SERVICE-ID) != 200:
    throw "RECONNECT_TOTAL_MISMATCH"
