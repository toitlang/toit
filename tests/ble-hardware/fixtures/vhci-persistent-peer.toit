// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.esp32
import system
import .hci-echo as fixture
import .vhci-persistent-server as server

main:
  20.repeat: | cycle/int |
    fixture.run (esp32.Esp32Transport) --count=10 --service-id=server.SERVICE-ID
    stats := system.process-stats --gc
    print "PERSISTENT_PEER cycle=$cycle allocated=$(stats[system.STATS-INDEX-ALLOCATED-MEMORY])"
    sleep --ms=500
  print "PERSISTENT_PEER COMPLETE cycles=20 exchanges=200"
