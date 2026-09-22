// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.esp32
import ble.experimental.hci
import ble.experimental.scanning
import system

main:
  controller := hci.Controller (esp32.Esp32Transport)
  // Literal SDK example payload, including its manufacturer data's FF FF prefix.
  expected := #[12, 9, 'T', 'o', 'i', 't', ' ', 'd', 'e', 'v', 'i', 'c', 'e',
                3, 3, 15, 24, 9, 255, 255, 255, 255, 255, 't', 'o', 'i', 't']
  counts := [0, 0]
  first := [0, 0]
  last := [0, 0]
  retained := []
  phase := 0
  statistics := scanning.Statistics
  try:
    hci.initialize controller
    print "SERVICE_ADVERTISE_OBSERVER READY"
    start := Time.monotonic-us
    failure := catch:
      with-timeout --ms=100_000:
        scanning.scan controller --active --no-filter-duplicates --statistics=statistics: | report |
          if report.address != #[0x2e, 0x76, 0x63, 0xac, 0xcd, 0x98]: continue.scan true
          if report.address-type != 0 or report.event-type != 3 or report.data != expected:
            throw "ADVERTISING_REPORT_MISMATCH"
          now := Time.monotonic-us
          if last[phase] != 0 and now - last[phase] > 3_000_000:
            phase++
            if phase > 1: throw "EXTRA_ADVERTISING_PHASE"
          if counts[phase] == 0: first[phase] = now
          last[phase] = now
          counts[phase]++
          if counts[phase] <= 10: retained.add report.data
          system.process-stats --gc
          retained.do: if it != expected: throw "RETAINED_ADVERTISEMENT_CHANGED"
          true
    if failure != DEADLINE-EXCEEDED-ERROR or Time.monotonic-us - start < 100_000_000:
      throw (failure or "EARLY_SCAN_EXIT")
    if not statistics.stopped or statistics.dropped-events != 0: throw "INCOMPLETE_SCAN"
    2.repeat: | index/int |
      if counts[index] < 50 or last[index] - first[index] < 10_000_000:
        throw "INSUFFICIENT_ADVERTISING_REPORTS"
    if Time.monotonic-us - last[1] < 5_000_000: throw "ADVERTISING_DID_NOT_STOP"
    if retained.size != 20: throw "MISSING_RETAINED_REPORTS"
    print "SERVICE_ADVERTISE_OBSERVER COMPLETE reports=$counts gap-us=$(first[1] - last[0]) retained=20 dropped=0"
  finally:
    critical-do --no-respect-deadline:
      controller.close
      controller.wait-closed
