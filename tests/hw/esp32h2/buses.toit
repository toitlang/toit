// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .session
import ..paired.buses as buses

main:
  session := Session
  try:
    buses.run session
        (IS-TESTEE ? 1 : 14)
        (IS-TESTEE ? 4 : 32)
        (IS-TESTEE ? 3 : 26)
        (IS-TESTEE ? 0 : 12)
        --testee-dma
        --no-tester-dma
    session.finish
  finally:
    session.close
