// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.esp32
import .bounded-radio as fixture

// S3 Board1 owns both roles; original ESP32 Board2 is its survivor peer.
main: run

run --winning/bool=false:
  fixture.run (esp32.Esp32Transport) #[0xae, 0xe0, 0x60, 0xac, 0xcd, 0x98]
      --winning=winning
