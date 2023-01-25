// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system.services
import expect

interface PingService:
  static UUID/string ::= "efc8fd7d-62ba-44bd-b215-5a819604aa28"
  static MAJOR/int   ::= 1
  static MINOR/int   ::= 2

  ping -> none
  static PING_INDEX ::= 0

main:
  tests := 0
  with_installed_services --priority_a=30 --priority_b=20:
    client := PingServiceClient
    client.ping
    expect.expect_equals "ping/A" client.name
    tests++

  with_installed_services --priority_a=20 --priority_b=30:
    client := PingServiceClient
    client.ping
    expect.expect_equals "ping/B" client.name
    tests++

  with_installed_services --priority_a=30 --priority_b=30:
    expect.expect_throw "Cannot disambiguate": PingServiceClient
    tests++

  expect.expect_equals 3 tests

with_installed_services --priority_a/int --priority_b/int [block]:
  service_a := PingServiceProvider "A" --priority=priority_a
  service_a.install
  service_b := PingServiceProvider "B" --priority=priority_b
  service_b.install

  try:
    block.call
  finally:
    service_a.uninstall
    service_b.uninstall

// ------------------------------------------------------------------

class PingServiceClient extends services.ServiceClient implements PingService:
  constructor --open/bool=true:
    super --open=open

  open -> PingServiceClient?:
    return (open_ PingService.UUID PingService.MAJOR PingService.MINOR) and this

  ping -> none:
    invoke_ PingService.PING_INDEX null

// ------------------------------------------------------------------

class PingServiceProvider extends services.ServiceProvider implements PingService services.ServiceHandler:
  identifier/string

  constructor .identifier --priority/int?=null:
    super "ping/$identifier" --major=1 --minor=2 --patch=5
    provides PingService.UUID PingService.MAJOR PingService.MINOR
        --priority=priority
        --handler=this

  handle pid/int client/int index/int arguments/any -> any:
    if index == PingService.PING_INDEX: return ping
    unreachable

  ping -> none:
    print "Ping $identifier"
