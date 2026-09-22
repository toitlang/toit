// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.esp32
import ble.experimental.hci
import ble.experimental.scanning
import system

import .hci-echo as fixture

main:
  service := fixture.wire-uuid "9f6c1000-8e2a-4b13-9e97-94f353eeb001"
  expected := #[2, 1, 6, 17, 7] + service
  2.repeat: | cycle/int |
    controller := hci.Controller (esp32.Esp32Transport)
    retained := []
    before := system.process-stats --gc
    try:
      hci.initialize controller
      with-timeout --ms=15_000:
        scanning.scan controller --no-filter-duplicates: | report |
          if report.address.reverse != #[8, 0xbe, 0xac, 0x2a, 0xda, 0xc2]: continue.scan true
          if not (report.has-service service): continue.scan true
          if report.data != expected: throw "SCAN_DATA_MISMATCH"
          retained.add report.data
          system.process-stats --gc
          retained.do: if it != expected: throw "RETAINED_SCAN_CHANGED"
          retained.size < 10
    finally:
      controller.close
      controller.wait-closed
    after := system.process-stats --gc
    retained.do: if it != expected: throw "RETAINED_SCAN_CHANGED"
    full-gcs := after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT]
    if retained.size != 10 or full-gcs < 10: throw "SCAN_GC_INCOMPLETE"
    print "VHCI_SCAN cycle=$cycle reports=$(retained.size) full-gcs=$full-gcs retained=true"
  print "VHCI_SCAN COMPLETE cycles=2"
