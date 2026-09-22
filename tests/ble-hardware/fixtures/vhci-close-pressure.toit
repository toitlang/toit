// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.esp32
import system
import .vhci-pressure as fixture

main:
  20.repeat: | cycle/int |
    radio := esp32.Esp32Transport
    try:
      initial := radio.diagnostics
      if initial.queued != 0 or initial.scan-drops != 0 or initial.fault:
        throw "QUEUE_REOPEN_DIRTY"
      fixture.command radio 0x0c03 #[]
      fixture.command radio 0x0c01 #[0, 0, 0, 0, 0, 0, 0, 0x20]
      fixture.command radio 0x2001 #[2, 0, 0, 0, 0, 0, 0, 0]
      fixture.command radio 0x200b #[0, 0x10, 0, 0x10, 0, 0, 0]
      fixture.command radio 0x200c #[1, 0]
      sleep --ms=1_500
      sample := radio.diagnostics
      if sample.queued != 6 or sample.scan-drops == 0 or sample.fault:
        throw "CLOSE_PRESSURE_MISSING"
      print "VHCI_CLOSE_PRESSURE queued=$sample.queued drops=$sample.scan-drops"
    finally:
      // Keep scanning enabled and the native queue occupied during teardown.
      radio.close
    stats := system.process-stats --gc
    print "VHCI_CLOSE_PRESSURE cycle=$cycle allocated=$(stats[system.STATS-INDEX-ALLOCATED-MEMORY]) free=$(stats[system.STATS-INDEX-SYSTEM-FREE-MEMORY]) largest=$(stats[system.STATS-INDEX-SYSTEM-LARGEST-FREE]) compacting-gcs=$(stats[system.STATS-INDEX-FULL-COMPACTING-GC-COUNT])"
  // Verify command exchange also works after the final pressured close.
  radio := esp32.Esp32Transport
  try:
    fixture.command radio 0x0c03 #[]
    fixture.command radio 0x1009 #[]
  finally:
    radio.close
  print "VHCI_CLOSE_PRESSURE COMPLETE cycles=20"
