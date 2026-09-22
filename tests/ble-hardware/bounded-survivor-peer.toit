// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.esp32
import .fixtures.hci-server as fixture

main:
  fixture.run (esp32.Esp32Transport) --no-dynamic --report-address
