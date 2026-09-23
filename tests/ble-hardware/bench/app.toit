// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// The application container for the Toit host side of the memory comparison:
// advertises one notifying characteristic and pushes notifications as fast as
// the service layer allows while a central is subscribed.

import ble.experimental.service.client as service
import monitor
import .stats as stats
import .uuids as uuids

CYCLES ::= 1000

main:
  stats.report "app" "boot"
  client := service.Client
  client.open --timeout=(Duration --s=10)
  stats.periodic "app"
  // The cost of one RPC round trip on this board, for attributing the
  // difference between the direct host and the provider model.
  calls := 500
  rpc-start := Time.monotonic-us
  calls.repeat: client.capabilities
  print "BENCH app rpc-round-trip-us=$((Time.monotonic-us - rpc-start) / calls)"
  payload := ByteArray uuids.PAYLOAD: it
  CYCLES.repeat: | cycle/int |
    session := client.configure --mtu-limit=517 --value-limit=512
    session.add-service uuids.SERVICE
    value := session.add-characteristic uuids.VALUE --read --notify --value=payload
    session.start (#[2, 1, 6, 17, 7] + uuids.SERVICE)
    if cycle == 0: stats.report "app" "advertising"
    session.peer
    stats.report "app" "connected" --extra=" cycle=$cycle"
    ended := monitor.Latch
    worker := task::
      error := catch: session.serve (: unreachable) (: unreachable): | _ _ | null
      ended.set error
    sent := 0
    started/int? := null
    // Alternate cycles use one RPC per notification and batched calls of 32,
    // to show the round-trip cost against the host's own.
    batched := cycle % 2 == 1
    batch := List 32: payload
    error := catch:
      while not ended.has-value:
        count := batched ? (session.notify-values value batch) : ((session.notify value) ? 1 : 0)
        if count > 0:
          if not started: started = Time.monotonic-us
          sent += count
        else:
          sleep --ms=5
    elapsed := started ? Time.monotonic-us - started : 0
    print "BENCH app cycle=$cycle batched=$batched sent=$sent us=$elapsed error=$error termination=$session.termination-reason"
    ended.get
    stats.report "app" "disconnected" --extra=" cycle=$cycle"
  stats.report "app" "done"
