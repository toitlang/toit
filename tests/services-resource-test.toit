// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system.services
import expect

interface ResourceService:
  static SELECTOR ::= services.ServiceSelector
      --uuid="74921323-3400-4d32-b8be-54b241daca05"
      --major=1
      --minor=2

  open key/string -> int
  static OPEN-INDEX ::= 0

  myclose handle/int -> none
  static MYCLOSE-INDEX ::= 1

  close-count key/string -> int
  static CLOSE-COUNT-INDEX ::= 2

main:
  test-resources
  test-resources --close
  test-resources --separate-process
  test-resources --close --separate-process
  test-uninstall
  test-multiple-resources
  test-custom-close

test-resources --close/bool=false --separate-process/bool=false:
  service := ResourceServiceProvider
  service.install
  expect.expect-equals -1 (service.close-count "resource-0")
  if separate-process:
    spawn::
      test-open "resource-0" close
  else:
    test-open "resource-0" close --close-client
  service.uninstall --wait
  expect.expect-equals 1 (service.close-count "resource-0")

test-uninstall:
  service := ResourceServiceProvider
  service.install
  clients := []
  clients.add (test-open "resource-1" false --no-close-client)
  expect.expect-equals 0 (service.close-count "resource-1")
  clients.add ResourceServiceClient
  expect.expect-equals 0 (service.close-count "resource-1")
  service.uninstall
  expect.expect-equals 1 (service.close-count "resource-1")

test-multiple-resources:
  service := ResourceServiceProvider
  service.install
  clients := []
  clients.add (test-open "resource-2" false)
  clients.add (test-open "resource-3" true)
  clients.add (test-open "resource-4" false)
  test-open "resource-5" true --close-client
  test-open "resource-6" false --close-client
  expect.expect-equals 0 (service.close-count "resource-2")
  expect.expect-equals 1 (service.close-count "resource-3")
  expect.expect-equals 0 (service.close-count "resource-4")
  expect.expect-equals 1 (service.close-count "resource-5")
  expect.expect-equals 1 (service.close-count "resource-6")

  clients.do: it.close
  expect.expect-equals 1 (service.close-count "resource-2")
  expect.expect-equals 1 (service.close-count "resource-3")
  expect.expect-equals 1 (service.close-count "resource-4")
  expect.expect-equals 1 (service.close-count "resource-5")
  expect.expect-equals 1 (service.close-count "resource-6")
  service.uninstall --wait

test-custom-close:
  service := ResourceServiceProvider
  service.install
  client := ResourceServiceClient
  client.open
  resource := ResourceProxy client "resource"
  expect.expect-equals 0 (service.close-count "resource")
  resource.myclose
  expect.expect-equals 1 (service.close-count "resource")
  resource.close
  expect.expect-equals 1 (service.close-count "resource")
  client.close
  service.uninstall --wait

test-open key/string close/bool --close-client/bool=false -> ResourceServiceClient:
  client := ResourceServiceClient
  client.open
  resource := ResourceProxy client key
  client.resources.add resource
  expect.expect-equals 0 (client.close-count key)
  if close:
    resource.close
    expect.expect-equals 1 (client.close-count key)
    resource.close
    expect.expect-equals 1 (client.close-count key)
  if close-client: client.close
  return client

// ------------------------------------------------------------------

class ResourceServiceClient extends services.ServiceClient implements ResourceService:
  resources/List ::= []  // Keep around to avoid GC and finalization behavior.

  static SELECTOR ::= ResourceService.SELECTOR
  constructor selector/services.ServiceSelector=SELECTOR:
    assert: selector.matches SELECTOR
    super selector

  open key/string -> int:
    return invoke_ ResourceService.OPEN-INDEX key

  myclose handle/int -> none:
    invoke_ ResourceService.MYCLOSE-INDEX handle

  close-count key/string -> int:
    return invoke_ ResourceService.CLOSE-COUNT-INDEX key

class ResourceProxy extends services.ServiceResourceProxy:
  constructor client/ResourceServiceClient key/string:
    super client (client.open key)

  myclose -> none:
    (client_ as ResourceServiceClient).myclose handle_

// ------------------------------------------------------------------

class ResourceServiceProvider extends services.ServiceProvider
    implements ResourceService services.ServiceHandler:
  resources/Map ::= {:}

  constructor:
    super "resource" --major=1 --minor=2 --patch=5
    provides ResourceService.SELECTOR --handler=this

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == ResourceService.OPEN-INDEX:
      return open client arguments
    if index == ResourceService.MYCLOSE-INDEX:
      resource ::= (resource client arguments) as Resource
      return myclose resource
    if index == ResourceService.CLOSE-COUNT-INDEX:
      return close-count arguments
    unreachable

  open key/string -> int:
    unreachable  // TODO(kasper): Nasty.

  open client/int key/string -> services.ServiceResource:
    resource := Resource this client key
    resources[key] = resource
    return resource

  myclose resource/Resource -> none:
    resource.close

  close-count key/string -> int:
    resource := resources.get key
    return resource ? resource.close-count : -1

class Resource extends services.ServiceResource:
  key/string ::= ?
  close-count_/int := 0

  constructor provider/services.ServiceProvider client/int .key:
    super provider client

  on-closed -> none:
    close-count_++

  close-count -> int:
    return close-count_
