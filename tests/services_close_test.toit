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

  list_clients -> List
  static LIST_CLIENTS_INDEX ::= 0

main:
  test_close
  test_close --separate_process

test_close --separate_process/bool=false:
  service := FooServiceProvider
  service.install
  if separate_process:
    spawn::
      client_0 := test_foo
      expect.expect_equals 1 client_0.list_clients.size
      client_1 := test_foo
      expect.expect_equals 2 client_0.list_clients.size
      expect.expect_equals 2 client_1.list_clients.size
      client_2 := test_foo --close
      expect.expect_equals 2 client_0.list_clients.size
      expect.expect_equals 2 client_1.list_clients.size
  else:
    expect.expect_equals 0 service.clients.size
    client := test_foo
    expect.expect_equals 1 service.clients.size
    test_foo --close
    expect.expect_equals 1 service.clients.size
    client.close
    expect.expect_equals 0 service.clients.size
  service.uninstall --wait
  expect.expect_equals 0 service.clients.size

test_foo --close=false -> FooServiceClient:
  client := FooServiceClient
  client.open
  clients := client.list_clients
  expect.expect_not_null clients
  expect.expect (clients.index_of client.id) >= 0
  if close:
    client.close
    expect.expect_throw "Client closed": client.list_clients
  return client

// ------------------------------------------------------------------

class FooServiceClient extends services.ServiceClient implements FooService:
  static SELECTOR ::= FooService.SELECTOR
  constructor selector/services.ServiceSelector=SELECTOR:
    assert: selector.matches SELECTOR
    super selector

  list_clients -> List:
    return List.from (invoke_ FooService.LIST_CLIENTS_INDEX null)

// ------------------------------------------------------------------

class FooServiceProvider extends services.ServiceProvider
    implements FooService services.ServiceHandlerNew:
  clients := {}

  constructor:
    super "foo" --major=1 --minor=1
    provides FooService.SELECTOR --handler=this --new

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == FooService.LIST_CLIENTS_INDEX: return list_clients
    unreachable

  on_opened client/int -> none:
    expect.expect_not (clients.contains client)
    clients.add client

  on_closed client/int -> none:
    expect.expect (clients.contains client)
    clients.remove client

  list_clients -> List:
    return List.from clients
