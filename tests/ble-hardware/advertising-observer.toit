// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.hci
import ble.experimental.linux
import ble.experimental.scanning

main args/List:
  if args.size != 1: throw "Usage: advertising-observer.toit <adapter index>"
  controller := hci.Controller (linux.LinuxTransport (int.parse args[0]))
  counts := [0, 0, 0]
  first := [0, 0, 0]
  last := [0, 0, 0]
  statistics := scanning.Statistics
  try:
    info := hci.initialize controller
    if info.address != #[0xc2, 0xda, 0x2a, 0xac, 0xbe, 8]: throw "WRONG_ADAPTER"
    print "ADVERTISING_OBSERVER READY"
    deadline := Time.monotonic-us + 55_000_000
    failure := catch:
      with-timeout --ms=55_000:
        scanning.scan controller --active --no-filter-duplicates --statistics=statistics: | report |
          if report.address != #[0xaa, 0x4d, 0x23, 0xf2, 0x3a, 8]: continue.scan true
          if report.address-type != 0: throw "WRONG_ADDRESS_TYPE"
          mode := -1
          if report.event-type == 4:
            if report.data != #[8, 9, 'T', 'o', 'i', 't', 'A', 'd', 'v']: throw "WRONG_SCAN_RESPONSE"
            mode = 2
          else:
            if report.data.size != 14: throw "WRONG_ADVERTISEMENT_SIZE"
            mode = report.data[13]
            if not 0 <= mode <= 1: throw "WRONG_MODE"
            if report.data != #[2, 1, 6, 10, 0xff, 0xff, 0xff, 't', 'o', 'i', 't', 'a', 'd', mode]:
              throw "WRONG_PAYLOAD"
            if report.event-type != (mode == 0 ? 3 : 2): throw "WRONG_EVENT_TYPE"
          now := Time.monotonic-us
          if counts[mode] == 0: first[mode] = now
          last[mode] = now
          counts[mode]++
          true
    if failure != DEADLINE-EXCEEDED-ERROR or Time.monotonic-us < deadline: throw (failure or "EARLY_SCAN_EXIT")
    if not statistics.stopped or statistics.dropped-events != 0: throw "INCOMPLETE_SCAN"
    3.repeat: | mode/int |
      if counts[mode] < 20 or last[mode] - first[mode] < 5_000_000: throw "INSUFFICIENT_REPEATED_REPORTS"
      if Time.monotonic-us - last[mode] < 5_000_000: throw "ADVERTISING_DID_NOT_STOP"
    if first[1] - last[0] < 2_000_000: throw "MISSING_STOP_GAP"
    print "ADVERTISING_OBSERVER COMPLETE reports=$counts gap-us=$(first[1] - last[0]) dropped=0"
  finally:
    controller.close
    controller.wait-closed
