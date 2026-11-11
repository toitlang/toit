// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import system.services show ServiceSelector ServiceProvider ServiceHandler ServiceClient TAG-UNTRUSTED-PROVIDER
import system.api.service-discovery show ServiceDiscoveryServiceClient
import .sandbox

/**
A sandbox whose launch policy grants it to provide services can do so, but
  only in the sandbox namespace.

A trusted client whose selector explicitly allows the "untrusted-provider"
  tag discovers and uses the sandbox's provider. The sandbox itself (like
  every sandbox) doesn't discover providers in sandboxes, not even when it
  opts in.
*/

interface GrantService:
  static SELECTOR ::= ServiceSelector
      --uuid="5a1b8e0e-3f0c-4d0e-9d6a-2b7e0d5c9a15"
      --major=1
      --minor=0

  who -> string
  static WHO-INDEX ::= 0

class GrantClient extends ServiceClient implements GrantService:
  constructor selector/ServiceSelector=GrantService.SELECTOR:
    super selector

  who -> string:
    return invoke_ GrantService.WHO-INDEX null

class GrantProvider extends ServiceProvider implements GrantService ServiceHandler:
  constructor:
    super "test/sandbox/grant" --major=1 --minor=0 --tags=["custom"]
    provides GrantService.SELECTOR --handler=this

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == GrantService.WHO-INDEX: return who
    unreachable

  who -> string:
    return "the sandbox"

OPT-IN ::= GrantService.SELECTOR.restrict.allow --tag=TAG-UNTRUSTED-PROVIDER

probe client/SiblingClient -> none:
  opted-in := GrantClient OPT-IN
  opted-in.open --timeout=(Duration --s=5)
  expect-equals "the sandbox" opted-in.who
  opted-in.close

  // The registration is in the sandbox namespace, whatever the sandbox
  // asked for.
  discovery := ServiceDiscoveryServiceClient
  discovery.open
  entry := (discovery.discover GrantService.SELECTOR.uuid --no-wait --untrusted-providers)[0]
  discovery.close
  expect-equals 7 entry.size
  expect-equals ["custom", TAG-UNTRUSTED-PROVIDER] entry[6]
  expect-equals ServiceProvider.PRIORITY-UNPREFERRED-STRONGLY entry[5]

main args:
  sandbox-test args --provide-services --error="DONE" --during=(:: probe it): | arguments/Map |
    provider := GrantProvider
    provider.install
    // Sandboxes don't discover providers in sandboxes, not even their own.
    discovery := ServiceDiscoveryServiceClient
    discovery.open
    if (discovery.discover GrantService.SELECTOR.uuid --no-wait --untrusted-providers)[0]:
      throw "DISCOVERED"
    discovery.close
    if not (catch: (GrantClient OPT-IN).open --timeout=(Duration --ms=200)): throw "OPENED"
    sleep --ms=3_000
    provider.uninstall
    throw "DONE"
