// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.esp32
import .connection-events as events
import .mixed-update-peer as fixture

main:
  with-timeout --ms=40_000:
    [100, 20].do: | reads/int |
      radio := events.ConnectionEvents (esp32.Esp32Transport)
      print "BOUNDED_FAILURE_PEER PHASE reads=$reads"
      try:
        fixture.run --timeout=(Duration --s=20) --radio=radio --reads=reads
      finally:
        critical-do --no-respect-deadline: radio.dump
    print "BOUNDED_FAILURE_PEER COMPLETE reads=120 opens=2 closes=2"
