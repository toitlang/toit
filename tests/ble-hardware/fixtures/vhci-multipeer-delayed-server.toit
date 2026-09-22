// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.esp32
import .hci-server as fixture

// First peer for the concurrent-link isolation probe, on lab ESP32 Board1.
main:
  fixture.run (esp32.Esp32Transport) --isolation-delay-ms=750
