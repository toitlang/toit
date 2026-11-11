// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import system.services show ServiceSelector ServiceProvider ServiceHandler ServiceClient TAG-UNTRUSTED-PROVIDER
import system.api.service-discovery show ServiceDiscoveryServiceClient
import .sandbox

/**
A sandbox can't squat a service that trusted clients expect.

The untrusted container's launch policy grants it to provide services, and
  it provides a service for which no trusted provider runs. Its provider
  lives in the sandbox namespace (the "untrusted-provider" tag): trusted
  clients with a plain selector, or with a selector that only denies
  other tags, never get it, and the discovery service doesn't even return
  it to them. Only a client that opts in sees it (see
  provider-grant-test.toit for its use).
*/

interface SquatService:
  static SELECTOR ::= ServiceSelector
      --uuid="5a1b8e0e-3f0c-4d0e-9d6a-2b7e0d5c9a14"
      --major=1
      --minor=0

  who -> string
  static WHO-INDEX ::= 0

class SquatClient extends ServiceClient implements SquatService:
  constructor selector/ServiceSelector=SquatService.SELECTOR:
    super selector

  who -> string:
    return invoke_ SquatService.WHO-INDEX null

class SquatProvider extends ServiceProvider implements SquatService ServiceHandler:
  constructor:
    super "test/sandbox/squat" --major=1 --minor=0
    provides SquatService.SELECTOR --handler=this

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == SquatService.WHO-INDEX: return who
    unreachable

  who -> string:
    return "the sandbox"

probe client/SiblingClient -> none:
  discovery := ServiceDiscoveryServiceClient
  discovery.open
  // Wait until the sandbox's provider is registered.
  with-timeout --ms=5_000:
    while not (discovery.discover SquatService.SELECTOR.uuid --no-wait --untrusted-providers)[0]:
      sleep --ms=10

  // A plain discovery doesn't return the sandbox's provider.
  expect-null (discovery.discover SquatService.SELECTOR.uuid --no-wait)[0]
  discovery.close

  // Trusted clients with a plain selector don't get it, although no
  // trusted provider of the service runs.
  plain := SquatClient
  expect-throw "Cannot find service": plain.open --timeout=(Duration --ms=200)

  // Neither do clients that restrict their selector without opting in.
  other := SquatClient (SquatService.SELECTOR.restrict.deny --tag="other")
  expect-throw "Cannot find service": other.open --timeout=(Duration --ms=200)
  denying := SquatClient (SquatService.SELECTOR.restrict.deny --tag=TAG-UNTRUSTED-PROVIDER)
  expect-throw "Cannot find service": denying.open --timeout=(Duration --ms=200)

main args:
  sandbox-test args --provide-services --error="DONE" --during=(:: probe it): | arguments/Map |
    provider := SquatProvider
    provider.install
    sleep --ms=3_000
    provider.uninstall
    throw "DONE"
