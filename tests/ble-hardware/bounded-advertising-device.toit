// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.esp32
import .bounded-advertising as probe

main:
  probe.run (esp32.Esp32Transport)
