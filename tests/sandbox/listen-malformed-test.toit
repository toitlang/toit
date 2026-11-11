// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system.api.service-discovery show ServiceDiscoveryService ServiceDiscoveryServiceClient
import .sandbox

/**
A sandbox can't break the discovery of a trusted service by registering a
  malformed provider for the same uuid.

The untrusted container registers providers for the sibling's uuid with
  a name, versions or tags of the wrong type (bypassing the typed client
  API); the system process must refuse all of them. While the untrusted
  container runs, the driver opens a new client of the sibling's service
  with a selector that denies untrusted providers, as the sandbox policy
  recommends. Clients look at every discovered entry: a tag that isn't a
  string was accepted and made every such client throw.
*/

MALFORMED ::= [
  // id, uuid, name, major, minor, priority, tags.
  [1001, SiblingService.SELECTOR.uuid, 42, 1, 0, 0, null],
  [1002, SiblingService.SELECTOR.uuid, "name", "1", 0, 0, null],
  [1003, SiblingService.SELECTOR.uuid, "name", 1, null, 0, null],
  [1004, SiblingService.SELECTOR.uuid, "name", 1, 0, 0, "tag"],
  [1005, SiblingService.SELECTOR.uuid, "name", 1, 0, 0, [42]],
  [1006, SiblingService.SELECTOR.uuid, "name", 1, 0, 0, ["tag", null]],
  ["1007", SiblingService.SELECTOR.uuid, "name", 1, 0, 0, null],
  [1008, 1234, "name", 1, 0, 0, null],
  [1009, SiblingService.SELECTOR.uuid, "name", 1, 0, "high", null],
]

open-restricted client/SiblingClient -> none:
  sleep --ms=1_500
  selector := SiblingService.SELECTOR.restrict.deny --tag="untrusted-provider"
  fresh := SiblingClient selector
  fresh.open --timeout=(Duration --s=2)
  if (fresh.ping 1) != 2: throw "WRONG_PING"
  fresh.close

main args:
  sandbox-test args --error="DONE" --during=(:: open-restricted it): | arguments/Map |
    discovery := ServiceDiscoveryServiceClient
    discovery.open
    accepted := 0
    MALFORMED.do: | entry |
      exception := catch: discovery.invoke_ ServiceDiscoveryService.LISTEN-INDEX entry
      if not exception: accepted++
    sleep --ms=3_000
    discovery.close
    if accepted != 0: throw "ACCEPTED $accepted"
    throw "DONE"
