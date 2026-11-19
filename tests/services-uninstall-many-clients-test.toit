// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Uninstalling a provider closes all its open clients. Closing a client
// removes it from the provider's client set, which shrinks and compacts the
// set once enough clients are gone: the iteration must not run over the set
// itself. Before the fix some clients were silently skipped (left open).

import expect show *
import system.services

interface FooService:
  static SELECTOR ::= services.ServiceSelector
      --uuid="a4b4f1a5-2f8e-4c0e-9b8b-6c5f3d6e7a10"
      --major=0
      --minor=0

  ping -> int
  static PING-INDEX ::= 0

main:
  [1, 2, 5, 6, 8, 13, 32].do: test it

test count/int:
  service := FooServiceProvider
  service.install
  clients := List count:
    client := FooServiceClient
    client.open
    expect-equals 42 client.ping
    client
  expect-equals count service.opened
  service.uninstall
  expect-equals count service.closed
  expect service.open-clients.is-empty

class FooServiceClient extends services.ServiceClient implements FooService:
  static SELECTOR ::= FooService.SELECTOR
  constructor selector/services.ServiceSelector=SELECTOR:
    assert: selector.matches SELECTOR
    super selector

  ping -> int:
    return invoke_ FooService.PING-INDEX null

class FooServiceProvider extends services.ServiceProvider
    implements FooService services.ServiceHandler:
  open-clients := {}
  opened := 0
  closed := 0

  constructor:
    super "foo" --major=1 --minor=0
    provides FooService.SELECTOR --handler=this

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == FooService.PING-INDEX: return ping
    unreachable

  ping -> int:
    return 42

  on-opened client/int -> none:
    open-clients.add client
    opened++

  on-closed client/int -> none:
    expect (open-clients.contains client)
    open-clients.remove client
    closed++
