// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// The Toit host without the service layer: one container owns the controller
// and pushes notifications directly through the GATT server, to separate the
// host's cost from the RPC round trip of the provider model.

import ble.experimental.attribute-server as attributes
import ble.experimental.central
import ble.experimental.esp32
import ble.experimental.gatt-server
import ble.experimental.hci
import monitor
import .stats as stats
import .uuids as uuids

CYCLES ::= 1000

main:
  stats.report "direct" "boot"
  payload := ByteArray 20: it
  controller := hci.Controller esp32.Esp32Transport
  info := hci.initialize controller
  host := central.Central controller --acl-length=info.acl-length --acl-count=info.acl-count
  database := attributes.Database.with-defaults --name="Toit bench"
  database.add-service uuids.SERVICE
  value := database.add-characteristic uuids.VALUE --read --notify --value=payload
  stats.report "direct" "initialized"
  stats.periodic "direct"
  advertisement := #[2, 1, 6, 17, 7] + uuids.SERVICE
  CYCLES.repeat: | cycle/int |
    if cycle == 0: stats.report "direct" "advertising"
    link := host.accept advertisement --timeout=(Duration --s=600)
    stats.report "direct" "connected" --extra=" cycle=$cycle"
    server := gatt-server.Server host link database
    ended := monitor.Latch
    worker := task::
      error := catch: server.serve: | _ _ | null
      ended.set error
    sent := 0
    started/int? := null
    // Per-call latency buckets: under 1 ms, 1 to 3 ms, over 3 ms. A flat
    // distribution means the host is CPU bound; a bimodal one means it waits
    // for controller credits.
    buckets := [0, 0, 0]
    total := 0
    error := catch:
      while not ended.has-value:
        before := Time.monotonic-us
        if server.notify value:
          if not started: started = Time.monotonic-us
          sent++
          took := Time.monotonic-us - before
          total += took
          buckets[took < 1000 ? 0 : took < 3000 ? 1 : 2]++
        else:
          sleep --ms=5
    elapsed := started ? Time.monotonic-us - started : 0
    print "BENCH direct cycle=$cycle sent=$sent us=$elapsed error=$error fast=$buckets[0] mid=$buckets[1] slow=$buckets[2] mean-us=$(sent > 0 ? total / sent : 0)"
    ended.get
    server.close
    stats.report "direct" "disconnected" --extra=" cycle=$cycle"
