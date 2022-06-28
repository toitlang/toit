// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system.services
import expect
import monitor

interface ResourceService:
  static UUID/string ::= "7ff1a5eb-27b7-4560-8861-7ebe0415e3cc"
  static MAJOR/int   ::= 1
  static MINOR/int   ::= 2

  static OPEN_INDEX ::= 0
  open key/string -> int

  static NOTIFY_INDEX ::= 1
  notify handle/int notification/any -> none

main:
  test_notify

test_notify:
  service := ResourceServiceDefinition
  service.install
  client := ResourceServiceClient
  resource := ResourceProxy client "resource"

  resource.notify 42
  expect.expect_equals 42 resource.notification

  resource.notify 87
  expect.expect_equals 87 resource.notification

  resource.notify 99
  resource.notify 101
  expect.expect_equals 99 resource.notification
  expect.expect_equals 101 resource.notification

  resource.notify "hestfisk"
  expect.expect_equals "hestfisk" resource.notification

  resource.close
  client.close
  service.uninstall --wait

// ------------------------------------------------------------------

class ResourceServiceClient extends services.ServiceClient implements ResourceService:
  resources/List ::= []  // Keep around to avoid GC and finalization behavior.

  constructor --open/bool=true:
    super --open=open

  open -> ResourceServiceClient?:
    return (open_ ResourceService.UUID ResourceService.MAJOR ResourceService.MINOR) and this

  open key/string -> int:
    return invoke_ ResourceService.OPEN_INDEX key

  notify handle/int notification/any -> none:
    invoke_ ResourceService.NOTIFY_INDEX [handle, notification]

class ResourceProxy extends services.ServiceResourceProxy:
  notifications_/monitor.Channel ::= monitor.Channel 8

  constructor client/ResourceServiceClient key/string:
    super client (client.open key)

  notify notification/any -> none:
    (client_ as ResourceServiceClient).notify handle_ notification

  notification -> any:
    return notifications_.receive

  on_notified_ notification/any -> none:
    notifications_.send notification

// ------------------------------------------------------------------

class ResourceServiceDefinition extends services.ServiceDefinition implements ResourceService:
  resources/Map ::= {:}

  constructor:
    super "resource" --major=1 --minor=2 --patch=5
    provides ResourceService.UUID ResourceService.MAJOR ResourceService.MINOR

  handle pid/int client/int index/int arguments/any -> any:
    if index == ResourceService.OPEN_INDEX:
      return open client arguments
    if index == ResourceService.NOTIFY_INDEX:
      resource ::= (resource client arguments[0]) as Resource
      return notify resource arguments[1]
    unreachable

  open key/string -> int:
    unreachable  // TODO(kasper): Nasty.

  open client/int key/string -> services.ServiceResource:
    resource := Resource this client key
    resources[key] = resource
    return resource

  notify resource/Resource notification/any -> none:
    resource.notify_ notification

class Resource extends services.ServiceResource:
  key/string ::= ?

  constructor service/services.ServiceDefinition client/int .key:
    super service client --notifiable

  on_closed -> none:
    // Do nothing.
