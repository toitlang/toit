// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import system

import .ble-hci-test as fixture

main:
  with-timeout --ms=30_000:
    // Warm the VM's task/exception paths before comparing live state.
    fixture.test-att-reconnect --wait-closed
    stats := system.process-stats --gc
    baseline := stats[system.STATS-INDEX-ALLOCATED-MEMORY]
    maximum := baseline
    minimum := baseline
    20.repeat:
      fixture.test-att-reconnect --wait-closed
      system.process-stats --gc stats
      live := stats[system.STATS-INDEX-ALLOCATED-MEMORY]
      maximum = max maximum live
      minimum = min minimum live
    print "software-reconnect cycles=400 baseline=$baseline min=$minimum max=$maximum"
    // Allow small runtime bookkeeping differences, but not retained link graphs.
    expect maximum <= baseline + 4096
