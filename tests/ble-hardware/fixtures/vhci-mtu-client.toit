// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.esp32
import system
import .hci-long-write as fixture
import .hci-trace as trace

main:
  before := system.process-stats --gc
  fixture.run (trace.Trace (esp32.Esp32Transport)) --mtu-limit=517 --exchange
  after := system.process-stats --gc
  print "VHCI_MTU_CLIENT COMPLETE full-gcs=$(after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT])"
