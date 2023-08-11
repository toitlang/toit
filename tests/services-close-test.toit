// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system.services
import expect

interface FooService:
  static SELECTOR ::= services.ServiceSelector
      --uuid="27d4a329-8b0a-4dcc-9e1c-2296475461fa"
      --major=0
      --minor=0

  list-clients -> List
  static LIST-CLIENTS-INDEX ::= 0

main:
  test-close
  test-close --separate-process

test-close --separate-process/bool=false:
  service := FooServiceProvider
  service.install
  if separate-process:
    spawn::
      client-0 := test-foo
      expect.expect-equals 1 client-0.list-clients.size
      client-1 := test-foo
      expect.expect-equals 2 client-0.list-clients.size
      expect.expect-equals 2 client-1.list-clients.size
      client-2 := test-foo --close
      expect.expect-equals 2 client-0.list-clients.size
      expect.expect-equals 2 client-1.list-clients.size
  else:
    expect.expect-equals 0 service.clients.size
    client := test-foo
    expect.expect-equals 1 service.clients.size
    test-foo --close
    expect.expect-equals 1 service.clients.size
    client.close
    expect.expect-equals 0 service.clients.size
  service.uninstall --wait
  expect.expect-equals 0 service.clients.size

test-foo --close=false -> FooServiceClient:
  client := FooServiceClient
  client.open
  clients := client.list-clients
  expect.expect-not-null clients
  expect.expect (clients.index-of client.id) >= 0
  if close:
    client.close
    expect.expect-throw "Client closed": client.list-clients
  return client

// ------------------------------------------------------------------

class FooServiceClient extends services.ServiceClient implements FooService:
  static SELECTOR ::= FooService.SELECTOR
  constructor selector/services.ServiceSelector=SELECTOR:
    assert: selector.matches SELECTOR
    super selector

  list-clients -> List:
    return List.from (invoke_ FooService.LIST-CLIENTS-INDEX null)

// ------------------------------------------------------------------

class FooServiceProvider extends services.ServiceProvider
    implements FooService services.ServiceHandler:
  clients := {}

  constructor:
    super "foo" --major=1 --minor=1
    provides FooService.SELECTOR --handler=this

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == FooService.LIST-CLIENTS-INDEX: return list-clients
    unreachable

  on-opened client/int -> none:
    expect.expect-not (clients.contains client)
    clients.add client

  on-closed client/int -> none:
    expect.expect (clients.contains client)
    clients.remove client

  list-clients -> List:
    return List.from clients
