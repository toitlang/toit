// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import system.api.service-discovery show ServiceDiscoveryService ServiceDiscoveryServiceClient
import .sandbox

/**
A sandbox can't make the RPC requests of other processes to the system
  process fail by flooding the system process' request queue.

The untrusted container sends RPC requests to the system process as fast
  as its mailbox quota allows, without waiting for the replies. The RPC
  broker of a process has room for 64 unprocessed requests; when they were
  all taken by the sandbox, the requests of every other client failed with
  "Cannot enqueue more requests". A single process now gets at most a
  quarter of the queue. The driver makes discovery requests while the
  flood runs: all of them must succeed.
*/

RPC-SERVICES-INVOKE ::= 302  // From lib/system/services.toit.
FLOOD-US ::= 3_000_000

probe client/SiblingClient -> none:
  discovery := ServiceDiscoveryServiceClient
  discovery.open
  sleep --ms=200
  ok := 0
  failed := 0
  start := Time.monotonic-us
  while Time.monotonic-us - start < FLOOD-US - 500_000:
    exception := catch: discovery.discover "no-such-service" --no-wait
    if exception:
      failed++
      if failed == 1: print "driver: $exception"
    else:
      ok++
  discovery.close
  print "driver: $ok requests succeeded, $failed failed"
  expect-equals 0 failed
  expect ok > 0

main args:
  sandbox-test args --error="DONE" --during=(:: probe it): | arguments/Map |
    discovery := ServiceDiscoveryServiceClient
    discovery.open
    id := discovery.id
    request := [RPC-SERVICES-INVOKE, [id, ServiceDiscoveryService.DISCOVER-INDEX, ["no-such-service", false]]]
    sent := 0
    start := Time.monotonic-us
    while Time.monotonic-us - start < FLOOD-US:
      exception := catch:
        process-send_ -1 SYSTEM-RPC-REQUEST_ [sent, request[0], request[1]]
      if exception:
        yield
      else:
        sent++
    // Let the system process drain the queue before we use it again.
    sleep --ms=500
    throw "DONE"
