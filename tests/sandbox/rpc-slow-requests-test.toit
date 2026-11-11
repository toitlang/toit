// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import .sandbox

/**
A sandbox can't take all the request processing tasks of a provider.

An RPC broker processes requests with at most 16 tasks. The untrusted
  container sends many slow requests to the sibling (each takes 3 s),
  without waiting for the replies. If its requests took all processing
  tasks, the requests of every other client would wait for them. The
  driver pings the sibling meanwhile: every ping must be answered
  quickly.
*/

RPC-SERVICES-INVOKE ::= 302  // From lib/system/services.toit.
SLOW-MS ::= 3_000

probe client/SiblingClient -> none:
  sleep --ms=500
  worst := 0
  10.repeat:
    t := Time.monotonic-us
    expect-equals 2 (client.ping 1)
    elapsed := Time.monotonic-us - t
    if elapsed > worst: worst = elapsed
    sleep --ms=100
  print "driver: worst ping $(worst / 1000) ms"
  expect worst < SLOW-MS * 1000 / 3

main args:
  sandbox-test args --error="DONE" --during=(:: probe it): | arguments/Map |
    sibling := discover-pid SiblingService.SELECTOR.uuid
    client := SiblingClient
    client.open
    sent := 0
    refused := 0
    64.repeat: | id |
      exception := catch:
        process-send_ sibling SYSTEM-RPC-REQUEST_ [10_000 + id, RPC-SERVICES-INVOKE, [client.id, SiblingService.SLOW-INDEX, SLOW-MS]]
      if exception: refused++
      else: sent++
    sleep --ms=(SLOW-MS + 500)
    client.close
    throw "DONE"
