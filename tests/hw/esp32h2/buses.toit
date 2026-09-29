// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .session
import .wiring
import ..paired.buses as buses

main:
  session := Session
  try:
    buses.run session
        SPI-CS
        SPI-CLOCK
        SPI-MOSI
        SPI-MISO
        --testee-dma
        --no-tester-dma
    session.finish
  finally:
    session.close
