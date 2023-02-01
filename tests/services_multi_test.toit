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

  with_installed_services --priority_a=30 --priority_b=30:
    client := (PingServiceClient --no-open).open --resolver=PreferB
    client.ping
    expect.expect_equals "ping/B" client.name
    tests++

  expect.expect_equals 4 tests

with_installed_services --priority_a/int --priority_b [block]:
  with_installed_services
      --create_a=(: PingServiceProvider.A --priority=priority_a)
      --create_b=(: PingServiceProvider.B --priority=priority_b)
      block

with_installed_services [--create_a] [--create_b] [block]:
  service_a := create_a.call
  service_a.install
  service_b := create_b.call
  service_b.install

  try:
    block.call
  finally:
    service_a.uninstall
    service_b.uninstall

// ------------------------------------------------------------------

class PreferB implements services.ServiceResolver:
  filter --name/string --major/int --minor/int --tags/List -> bool:
    if name != "ping/B": return false
    expect.expect_equals PingServiceProvider.MAJOR_B major
    expect.expect_equals PingServiceProvider.MINOR_B minor
    expect.expect_list_equals [] tags
    return true

class PingServiceClient extends services.ServiceClient implements PingService:
  constructor --open/bool=true:
    super --open=open

  open -> PingServiceClient?:
    return (open_ PingService.UUID PingService.MAJOR PingService.MINOR) and this

  open --resolver/services.ServiceResolver -> PingServiceClient?:
    return (open_ PingService.UUID PingService.MAJOR PingService.MINOR --resolver=resolver) and this

  ping -> none:
    invoke_ PingService.PING_INDEX null

// ------------------------------------------------------------------

class PingServiceProvider extends services.ServiceProvider:
  static MAJOR_A ::= 1
  static MINOR_A ::= 2
  static MAJOR_B ::= 3
  static MINOR_B ::= 4

  constructor.A --priority/int?=null:
    super "ping/A" --major=MAJOR_A --minor=MINOR_A --patch=5
    provides PingService.UUID PingService.MAJOR PingService.MINOR
        --handler=PingHandler "A"
        --priority=priority

  constructor.B --priority/int?=null:
    super "ping/B" --major=MAJOR_B --minor=MINOR_B --patch=17
    provides PingService.UUID PingService.MAJOR PingService.MINOR
        --handler=PingHandler "B"
        --priority=priority

class PingHandler implements services.ServiceHandler PingService:
  identifier/string
  constructor .identifier:

  handle pid/int client/int index/int arguments/any -> any:
    if index == PingService.PING_INDEX: return ping
    unreachable

  ping -> none:
    print "Ping $identifier"
