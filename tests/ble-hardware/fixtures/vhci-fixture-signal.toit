// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.esp32
import ble.experimental.hci
import ble.experimental.scanning
import .vhci-bond-revocation-peer as fixture

// Passive observer on S3 Board2. Measures its own reception, not the central's
// reception or connection-channel packet loss. Never logs unrelated advertisers.
main:
  controller := hci.Controller (esp32.Esp32Transport)
  count := [0, 0]
  total := [0, 0]
  weakest := [20, 20]
  strongest := [-127, -127]
  addresses := [fixture.peer-address 0, fixture.peer-address 1]
  statistics := scanning.Statistics
  try:
    info := hci.initialize controller
    if info.address != #[0x3a, 0x0b, 0xa0, 0x03, 0xf7, 0x84]: throw "SIGNAL_WRONG_BOARD"
    print "SIGNAL_SCAN READY passive=true duration-ms=20000"
    error := catch:
      with-timeout --ms=20_000:
        scanning.scan controller --no-active --no-filter-duplicates --statistics=statistics: | report |
          if report.address-type != 0 or report.rssi == null: continue.scan true
          index := addresses.index-of report.address
          if index < 0: continue.scan true
          count[index]++
          total[index] += report.rssi
          weakest[index] = min weakest[index] report.rssi
          strongest[index] = max strongest[index] report.rssi
          true
    if error != DEADLINE-EXCEEDED-ERROR: throw (error or "SIGNAL_SCAN_EARLY_END")
    if not statistics.stopped: throw "SIGNAL_SCAN_NOT_STOPPED"
    2.repeat: | index/int |
      mean := count[index] == 0 ? null : total[index] / count[index]
      print "SIGNAL_SCAN peer=$index count=$(count[index]) min=$(weakest[index]) max=$(strongest[index]) mean=$mean"
    if count.contains 0: throw "SIGNAL_PEER_MISSING"
    print "SIGNAL_SCAN COMPLETE dropped-events=$statistics.dropped-events stopped=true"
  finally:
    controller.close
    controller.wait-closed
