// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.esp32
import .hci-server as fixture

// Matches the numbered reconnect campaign while keeping one controller alive.
main:
  count := fixture.run (esp32.Esp32Transport)
      --cycles=1000
      --warmup=3
      --numbered-cycles
      --expected-count=10
      --receive-acl-packets=4
  if count != 10030: throw "RECONNECT_TOTAL_MISMATCH"
