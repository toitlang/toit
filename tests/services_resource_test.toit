// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system.services
import expect

interface ResourceService:
  static UUID/string ::= "74921323-3400-4d32-b8be-54b241daca05"
  static MAJOR/int   ::= 1
  static MINOR/int   ::= 2

  static OPEN_INDEX ::= 0
  open key/string -> int

  static MYCLOSE_INDEX ::= 1
  myclose handle/int -> none

  static CLOSE_COUNT_INDEX ::= 2
  close_count key/string -> int

main:
  test_resources
  test_resources --close
  test_resources --separate_process
  test_resources --close --separate_process
  test_uninstall
  test_multiple_resources
  test_custom_close

test_resources --close/bool=false --separate_process/bool=false:
  service := ResourceServiceDefinition
  service.install
  expect.expect_equals -1 (service.close_count "resource-0")
  if separate_process:
    spawn::
      test_open "resource-0" close
  else:
    test_open "resource-0" close --close_client
  service.uninstall --wait
  expect.expect_equals 1 (service.close_count "resource-0")

test_uninstall:
  service := ResourceServiceDefinition
  service.install
  clients := []
  clients.add (test_open "resource-1" false --no-close_client)
  expect.expect_equals 0 (service.close_count "resource-1")
  clients.add ResourceServiceClient
  expect.expect_equals 0 (service.close_count "resource-1")
  service.uninstall
  expect.expect_equals 1 (service.close_count "resource-1")

test_multiple_resources:
  service := ResourceServiceDefinition
  service.install
  clients := []
  clients.add (test_open "resource-2" false)
  clients.add (test_open "resource-3" true)
  clients.add (test_open "resource-4" false)
  test_open "resource-5" true --close_client
  test_open "resource-6" false --close_client
  expect.expect_equals 0 (service.close_count "resource-2")
  expect.expect_equals 1 (service.close_count "resource-3")
  expect.expect_equals 0 (service.close_count "resource-4")
  expect.expect_equals 1 (service.close_count "resource-5")
  expect.expect_equals 1 (service.close_count "resource-6")

  clients.do: it.close
  expect.expect_equals 1 (service.close_count "resource-2")
  expect.expect_equals 1 (service.close_count "resource-3")
  expect.expect_equals 1 (service.close_count "resource-4")
  expect.expect_equals 1 (service.close_count "resource-5")
  expect.expect_equals 1 (service.close_count "resource-6")
  service.uninstall --wait

test_custom_close:
  service := ResourceServiceDefinition
  service.install
  client := ResourceServiceClient
  resource := ResourceProxy client "resource"
  expect.expect_equals 0 (service.close_count "resource")
  resource.myclose
  expect.expect_equals 1 (service.close_count "resource")
  resource.close
  expect.expect_equals 1 (service.close_count "resource")
  client.close
  service.uninstall --wait

test_open key/string close/bool --close_client/bool=false -> ResourceServiceClient:
  client := ResourceServiceClient
  resource := ResourceProxy client key
  client.resources.add resource
  expect.expect_equals 0 (client.close_count key)
  if close:
    resource.close
    expect.expect_equals 1 (client.close_count key)
    resource.close
    expect.expect_equals 1 (client.close_count key)
  if close_client: client.close
  return client

// ------------------------------------------------------------------

class ResourceServiceClient extends services.ServiceClient implements ResourceService:
  resources/List ::= []  // Keep around to avoid GC and finalization behavior.

  constructor --open/bool=true:
    super --open=open

  open -> ResourceServiceClient?:
    return (open_ ResourceService.UUID ResourceService.MAJOR ResourceService.MINOR) and this

  open key/string -> int:
    return invoke_ ResourceService.OPEN_INDEX key

  myclose handle/int -> none:
    invoke_ ResourceService.MYCLOSE_INDEX handle

  close_count key/string -> int:
    return invoke_ ResourceService.CLOSE_COUNT_INDEX key

class ResourceProxy extends services.ServiceResourceProxy:
  constructor client/ResourceServiceClient key/string:
    super client (client.open key)

  myclose -> none:
    (client_ as ResourceServiceClient).myclose handle_

// ------------------------------------------------------------------

class ResourceServiceDefinition extends services.ServiceDefinition implements ResourceService:
  resources/Map ::= {:}

  constructor:
    super "resource" --major=1 --minor=2 --patch=5
    provides ResourceService.UUID ResourceService.MAJOR ResourceService.MINOR

  handle pid/int client/int index/int arguments/any -> any:
    if index == ResourceService.OPEN_INDEX:
      return open client arguments
    if index == ResourceService.MYCLOSE_INDEX:
      resource ::= (resource client arguments) as Resource
      return myclose resource
    if index == ResourceService.CLOSE_COUNT_INDEX:
      return close_count arguments
    unreachable

  open key/string -> int:
    unreachable  // TODO(kasper): Nasty.

  open client/int key/string -> services.ServiceResource:
    resource := Resource this client key
    resources[key] = resource
    return resource

  myclose resource/Resource -> none:
    resource.close

  close_count key/string -> int:
    resource := resources.get key
    return resource ? resource.close_count : -1

class Resource extends services.ServiceResource:
  key/string ::= ?
  close_count_/int := 0

  constructor service/services.ServiceDefinition client/int .key:
    super service client

  on_closed -> none:
    close_count_++

  close_count -> int:
    return close_count_
