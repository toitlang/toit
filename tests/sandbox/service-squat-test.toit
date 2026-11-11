// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import system.services show ServiceSelector ServiceProvider ServiceHandler ServiceClient
import .sandbox

/**
Characterizes service squatting by a sandbox. This test documents an
  open design gap (see "Threats tested" in docs/sandbox-policy.md); it
  asserts the current behavior and must be updated when the gap is
  closed.

A sandbox can provide any service. Its providers get the lowest priority
  and the "untrusted-provider" tag, so they never win against a trusted
  provider of the same service. But while no trusted provider is
  registered (for example during boot, or after the trusted provider
  crashed), a trusted client with a plain selector opens the sandbox's
  provider. Only clients that deny the tag are safe.
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
  plain := SquatClient
  plain.open --timeout=(Duration --s=5)
  // GAP: a trusted client with a plain selector talks to the sandbox.
  expect-equals "the sandbox" plain.who
  plain.close

  restricted := SquatClient (SquatService.SELECTOR.restrict.deny --tag="untrusted-provider")
  expect-throw "Cannot find service": restricted.open --timeout=(Duration --ms=200)

main args:
  sandbox-test args --error="DONE" --during=(:: probe it): | arguments/Map |
    provider := SquatProvider
    provider.install
    sleep --ms=3_000
    provider.uninstall
    throw "DONE"
