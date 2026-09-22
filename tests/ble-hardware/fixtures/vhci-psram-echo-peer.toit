// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.esp32
import .hci-server as fixture

// Isolated service UUID prevents interference with the reconnect campaign.
main:
  fixture.run (esp32.Esp32Transport)
      --service-id="9f6c1100-8e2a-4b13-9e97-94f353eeb001"
