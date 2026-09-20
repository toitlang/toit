// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system
import .wiring
import ..paired.session as paired

IS-TESTEE ::= system.architecture == system.ARCHITECTURE-ESP32H2

class Session extends paired.Session:
  constructor --completed/int=0 --baud-rate/int=115200:
    super --is-testee=IS-TESTEE
        --rx=(IS-TESTEE ? H2-RX : HELPER-RX)
        --tx=(IS-TESTEE ? H2-TX : HELPER-TX)
        --completed=completed
        --baud-rate=baud-rate
