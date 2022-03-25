// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system.services
import expect

interface FooService:
  static NAME/string ::= "foo"
  static MAJOR/int   ::= 0
  static MINOR/int   ::= 0

  static GET_CLIENTS_INDEX ::= 0
  get_clients -> List

main:
  test_close
  test_close --separate_process

test_close --separate_process/bool=false:
  service := FooServiceDefinition
  service.install
  if separate_process:
    spawn::
      client_0 := test_foo
      expect.expect_equals 1 client_0.get_clients.size
      client_1 := test_foo
      expect.expect_equals 1 client_0.get_clients.size
      expect.expect_equals 1 client_1.get_clients.size
      client_2 := test_foo --close
      expect.expect_equals 1 client_0.get_clients.size
      expect.expect_equals 1 client_1.get_clients.size
  else:
    expect.expect_equals 0 service.clients.size
    client := test_foo
    expect.expect_equals 1 service.clients.size
    test_foo --close
    expect.expect_equals 1 service.clients.size
    client.close
    expect.expect_equals 0 service.clients.size
  service.wait
  expect.expect_equals 0 service.clients.size

test_foo --close=false -> FooServiceClient:
  client := FooServiceClient.lookup
  clients := client.get_clients
  expect.expect_not_null clients
  expect.expect (clients.index_of current_process_) >= 0
  if close:
    client.close
    expect.expect_throw "Client closed": client.get_clients
  return client

// ------------------------------------------------------------------

class FooServiceClient extends services.ServiceClient implements FooService:
  constructor.lookup name=FooService.NAME major=FooService.MAJOR minor=FooService.MINOR:
    super.lookup name major minor

  get_clients -> List:
    return List.from (invoke_ FooService.GET_CLIENTS_INDEX null)

// ------------------------------------------------------------------

class FooServiceDefinition extends services.ServiceDefinition implements FooService:
  clients := {}

  constructor:
    super FooService.NAME --major=FooService.MAJOR --minor=FooService.MINOR

  open client/int -> none:
    expect.expect_not (clients.contains client)
    clients.add client
    super client

  close client/int -> none:
    expect.expect (clients.contains client)
    clients.remove client
    super client

  handle index/int arguments/any -> any:
    if index == FooService.GET_CLIENTS_INDEX: return get_clients
    unreachable

  get_clients -> List:
    return List.from clients
