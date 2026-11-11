// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import rpc
import system.api.service-discovery show ServiceDiscoveryService ServiceDiscoveryServiceClient
import .sandbox

/**
A sandbox can't use, close or close the resources of service clients of
  other processes, even when it knows their client ids.

Client ids and resource handles are small integers that travel in RPC
  arguments. The driver gives the untrusted container the ids of its own
  discovery client (provided by the system process) and of its sibling
  client. The untrusted container invokes methods on them, closes them and
  closes guessed resource handles of them, at the system process and at
  the sibling. Every attempt must fail with SERVICE_CLIENT_NOT_OWNED, and
  the driver's clients must keep working.
*/

// From lib/system/services.toit.
RPC-SERVICES-CLOSE ::= 301
RPC-SERVICES-INVOKE ::= 302
RPC-SERVICES-CLOSE-RESOURCE ::= 303

NOT-OWNED ::= "SERVICE_CLIENT_NOT_OWNED"

driver-discovery/ServiceDiscoveryServiceClient? := null

prepare client/SiblingClient -> Map:
  driver-discovery = ServiceDiscoveryServiceClient
  driver-discovery.open
  return {
    "discovery-id": driver-discovery.id,
    "sibling-client-id": client.id,
  }

check client/SiblingClient -> none:
  sleep --ms=1_500
  expect-equals [null, null] (driver-discovery.discover "no-such-service" --no-wait)
  expect-equals 6 (client.ping 5)
  driver-discovery.close

expect-not-owned [block] -> none:
  exception := catch block
  if exception != NOT-OWNED: throw "EXPECTED $NOT-OWNED, GOT $exception"

main args:
  sandbox-test args --error="DONE" --prepare=(:: prepare it) --during=(:: check it): | arguments/Map |
    discovery-id := arguments["discovery-id"]
    sibling-client-id := arguments["sibling-client-id"]

    // The driver's discovery client, at the system process.
    expect-not-owned:
      rpc.invoke -1 RPC-SERVICES-INVOKE [discovery-id, ServiceDiscoveryService.DISCOVER-INDEX, ["x", false]]
    expect-not-owned:
      rpc.invoke -1 RPC-SERVICES-INVOKE [discovery-id, ServiceDiscoveryService.UNLISTEN-INDEX, 0]
    16.repeat: | handle |
      expect-not-owned: rpc.invoke -1 RPC-SERVICES-CLOSE-RESOURCE [discovery-id, handle]
    expect-not-owned: rpc.invoke -1 RPC-SERVICES-CLOSE discovery-id

    // The driver's sibling client, at the sibling.
    sibling := discover-pid SiblingService.SELECTOR.uuid
    expect-not-owned:
      rpc.invoke sibling RPC-SERVICES-INVOKE [sibling-client-id, SiblingService.PING-INDEX, 1]
    16.repeat: | handle |
      expect-not-owned: rpc.invoke sibling RPC-SERVICES-CLOSE-RESOURCE [sibling-client-id, handle]
    expect-not-owned: rpc.invoke sibling RPC-SERVICES-CLOSE sibling-client-id

    // Wait until the driver has checked its clients.
    sleep --ms=2_500
    throw "DONE"
