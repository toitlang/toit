// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.esp32
import system
import .hci-server as fixture
import .vhci-central-provider as diagnostics

// Diagnostic variant of the twenty-lifetime reconnect fixture. Captures only
// bounded HCI headers and whitelisted public connection/advertising statuses.
main: run

run --persistent/bool=false:
  if persistent:
    if (fixture.run Radio --cycles=20 --expected-count=10) != 200:
      throw "RECONNECT_TOTAL_MISMATCH"
    return
  20.repeat: | cycle/int |
    if (fixture.run Radio) != 10: throw "RECONNECT_COUNT_MISMATCH"
    stats := system.process-stats --gc
    print "VHCI_RECONNECT cycle=$cycle allocated=$(stats[system.STATS-INDEX-ALLOCATED-MEMORY])"
  print "VHCI_RECONNECT COMPLETE cycles=20 warmup=0 diagnostics=true"

class Radio extends diagnostics.Diagnostics:
  advertising-records_/int := 0

  constructor:
    super (esp32.Esp32Transport)

  receive -> ByteArray:
    packet := super
    if advertising-records_ < 64 and packet.size == 7 and
        packet[..3] == #[4, 0x0e, 4] and packet[4..6] == #[0x0a, 0x20]:
      advertising-records_++
      print "RECONNECT_RADIO advertising-complete status=$(packet[6]) us=$(Time.monotonic-us)"
    return packet
