// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system
import ..esp32.i2s-shared as shared

main args:
  h2 := system.architecture == system.ARCHITECTURE-ESP32H2
  shared.test args
      --board1=h2
      --data=(h2 ? 3 : 26)
      --clk=(h2 ? 1 : 14)
      --ws=(h2 ? 4 : 32)
      --mclk=(h2 ? 0 : 12)
