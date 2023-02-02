// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system.services
import expect

interface PingService:
  static SELECTOR ::= services.ServiceSelector
      --uuid="efc8fd7d-62ba-44bd-b215-5a819604aa28"
      --major=7
      --minor=9

  ping -> none
  static PING_INDEX ::= 0

main:
  test_positive
  test_negative
  test_errors

test_positive:
  tests := 0
  with_installed_services --priority_a=30 --priority_b=20:
    client := PingServiceClient
    client.open
    client.ping
    expect.expect_equals "ping/A" client.name
    tests++

  with_installed_services --priority_a=20 --priority_b=30:
    client := PingServiceClient
    client.open
    client.ping
    expect.expect_equals "ping/B" client.name
    tests++

  with_client (PingService.SELECTOR.restrict.allow --name="ping/B"): | client/PingServiceClient |
    expect.expect_equals "ping/B" client.name
    tests++

  with_client (PingService.SELECTOR.restrict.allow --name="ping/B" --major=3): | client/PingServiceClient |
    expect.expect_equals "ping/B" client.name
    tests++

  with_client (PingService.SELECTOR.restrict.allow --name="ping/B" --major=3 --minor=4): | client/PingServiceClient |
    expect.expect_equals "ping/B" client.name
    tests++

  with_client (PingService.SELECTOR.restrict.allow --tag="A"): | client/PingServiceClient |
    expect.expect_equals "ping/A" client.name
    tests++

  with_client (PingService.SELECTOR.restrict.allow --tag="B"): | client/PingServiceClient |
    expect.expect_equals "ping/B" client.name
    tests++

  with_client (PingService.SELECTOR.restrict.allow --tag="!A"): | client/PingServiceClient |
    expect.expect_equals "ping/B" client.name
    tests++

  // Look for either the non-exisiting 'nope' tag or B.
  selector := PingService.SELECTOR.restrict.allow --tags=["nope", "B"]
  with_client selector: | client/PingServiceClient |
    expect.expect_equals "ping/B" client.name
    tests++

  with_client (PingService.SELECTOR.restrict.deny --name="ping/A"): | client/PingServiceClient |
    expect.expect_equals "ping/B" client.name
    tests++

  with_client (PingService.SELECTOR.restrict.deny --tag="A"): | client/PingServiceClient |
    expect.expect_equals "ping/B" client.name
    tests++

  with_client (PingService.SELECTOR.restrict.deny --name="ping/B" --major=3): | client/PingServiceClient |
    expect.expect_equals "ping/A" client.name
    tests++



  with_client (PingService.SELECTOR.restrict.deny --name="ping/B" --major=3 --minor=4): | client/PingServiceClient |
    expect.expect_equals "ping/A" client.name
    tests++

  selector = PingService.SELECTOR.restrict
  selector.allow --name="ping/B" --major=3 --minor=4
  selector.deny --name="ping/B" --major=33 --minor=44
  with_client selector: | client/PingServiceClient |
    expect.expect_equals "ping/B" client.name
    tests++

  selector = PingService.SELECTOR.restrict
  selector.allow --name="ping/B" --major=33 --minor=44
  selector.allow --name="ping/B" --major=3 --minor=4
  selector.allow --name="ping/B" --major=333 --minor=444
  with_client selector: | client/PingServiceClient |
    expect.expect_equals "ping/B" client.name
    tests++

  selector.allow --name="ping/A" --major=11 --minor=22
  selector.allow --name="ping/A" --major=1 --minor=22
  selector.allow --name="ping/A" --major=11 --minor=2
  with_client selector: | client/PingServiceClient |
    expect.expect_equals "ping/B" client.name
    tests++

  expect.expect_equals 16 tests

test_negative:
  expect.expect_throw "Cannot disambiguate":
    with_client PingService.SELECTOR: unreachable

  expect.expect_throw "Cannot disambiguate":
    with_client (PingService.SELECTOR.restrict.allow --tag="yada"): unreachable

  expect.expect_throw "Cannot disambiguate":
    with_client (PingService.SELECTOR.restrict.allow --tag="yada"): unreachable

  expect.expect_throw "Cannot disambiguate":
    with_client (PingService.SELECTOR.restrict.deny --name="ping/B" --major=33): unreachable

  expect.expect_throw "Cannot disambiguate":
    with_client (PingService.SELECTOR.restrict.deny --name="ping/B" --major=3 --minor=44): unreachable

  expect.expect_throw "Cannot disambiguate":
    with_client (PingService.SELECTOR.restrict.deny --name="ping/B" --major=33 --minor=44): unreachable

  expect.expect_throw "Cannot disambiguate":
    // Look for either tag B or yada. Both have yada.
    selector := PingService.SELECTOR.restrict.allow --tags=["B", "yada"]
    with_client selector: unreachable

  // Look for anything that doesn't have the non-existing tag 'nope'.
  expect.expect_throw "Cannot disambiguate":
    with_client (PingService.SELECTOR.restrict.deny --tag="nope"): unreachable

  expect.expect_throw "Cannot disambiguate":
    selector := PingService.SELECTOR.restrict
    selector.allow --name="ping/A" --major=11 --minor=22
    selector.allow --name="ping/A" --major=1 --minor=2
    selector.allow --name="ping/A" --major=111 --minor=222
    selector.allow --name="ping/B" --major=33 --minor=44
    selector.allow --name="ping/B" --major=3 --minor=4
    selector.allow --name="ping/B" --major=333 --minor=444
    with_client selector: unreachable

  expect.expect_throw "Cannot find service":
    with_client (PingService.SELECTOR.restrict.deny --tag="yada"): unreachable

  expect.expect_throw "Cannot find service":
    with_client (PingService.SELECTOR.restrict.allow --tag="nope"): unreachable

  expect.expect_throw "Cannot find service":
    // Look for tag B, but not yada.
    selector := PingService.SELECTOR.restrict
    selector.allow --tag="B"
    selector.deny --tag="yada"
    with_client selector: unreachable

  expect.expect_throw "Cannot find service":
    with_client (PingService.SELECTOR.restrict.allow --name="ping/B" --major=33): unreachable

  expect.expect_throw "Cannot find service":
    with_client (PingService.SELECTOR.restrict.allow --name="ping/B" --major=33 --minor=4): unreachable

  expect.expect_throw "Cannot find service":
    with_client (PingService.SELECTOR.restrict.allow --name="ping/B" --major=3 --minor=44): unreachable

test_errors:
  expect.expect_throw "Must have major version to match on minor":
    selector := PingService.SELECTOR.restrict
    selector.allow --name="fusk" --minor=2

  expect.expect_throw "Must have major version to match on minor":
    selector := PingService.SELECTOR.restrict
    selector.deny --name="fusk" --minor=2

  expect.expect_throw "Cannot have multiple entries for the same named version":
    selector := PingService.SELECTOR.restrict
    selector.allow --name="fusk"
    selector.allow --name="fusk" --major=1

  expect.expect_throw "Cannot have multiple entries for the same named version":
    selector := PingService.SELECTOR.restrict
    selector.allow --name="fusk"
    selector.allow --name="fusk" --major=1 --minor=2

  expect.expect_throw "Cannot have multiple entries for the same named version":
    selector := PingService.SELECTOR.restrict
    selector.allow --name="fusk"
    selector.deny --name="fusk"

  expect.expect_throw "Cannot allow and deny the same tag":
    selector := PingService.SELECTOR.restrict
    selector.allow --tag="kuks"
    selector.deny --tag="kuks"

with_client selector/services.ServiceSelector [block]:
  with_installed_services:
    client := PingServiceClient selector
    client.open
    client.ping
    block.call client

with_installed_services --priority_a/int?=null --priority_b/int?=null [block]:
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

class PingServiceClient extends services.ServiceClient implements PingService:
  constructor selector/services.ServiceSelector=PingService.SELECTOR:
    super selector

  ping -> none:
    invoke_ PingService.PING_INDEX null

// ------------------------------------------------------------------

class PingServiceProvider extends services.ServiceProvider:
  constructor.A --priority/int?=null:
    super "ping/A" --major=1 --minor=2 --patch=5 --tags=["yada"]
    provides PingService.SELECTOR
        --handler=PingHandler "A"
        --priority=priority
        --tags=["A", "!B"]

  constructor.B --priority/int?=null:
    super "ping/B" --major=3 --minor=4 --patch=17 --tags=["yada"]
    provides PingService.SELECTOR
        --handler=PingHandler "B"
        --priority=priority
        --tags=["!A", "B"]

class PingHandler implements services.ServiceHandler PingService:
  identifier/string
  constructor .identifier:

  handle pid/int client/int index/int arguments/any -> any:
    if index == PingService.PING_INDEX: return ping
    unreachable

  ping -> none:
    print "Ping $identifier"
