// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.esp32
import system
import .hci-echo as fixture

main:
  stats := system.process-stats --gc
  free := stats[system.STATS-INDEX-SYSTEM-FREE-MEMORY]
  if free < 1_000_000: throw "PSRAM_NOT_IN_USE"
  print "VHCI_PSRAM_ECHO READY free=$free"
  fixture.run (esp32.Esp32Transport) --count=100 --log-every=10
      --service-id="9f6c1100-8e2a-4b13-9e97-94f353eeb001"
  print "VHCI_PSRAM_ECHO COMPLETE"
