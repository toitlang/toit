// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system.services
import expect show *

interface PingService:
  static SELECTOR ::= services.ServiceSelector
      --uuid="efc8fd7d-62ba-44bd-b215-5a819604aa28"
      --major=7
      --minor=9

  ping -> none
  static PING-INDEX ::= 0

main:
  test-positive
  test-negative
  test-errors

test-positive:
  tests-started := 0
  tests-run := 0

  tests-started++
  with-installed-services
      --priority-a=services.ServiceProvider.PRIORITY-PREFERRED
      --priority-b=services.ServiceProvider.PRIORITY-NORMAL:
    client := PingServiceClient
    client.open
    client.ping
    expect-equals "ping/A" client.name
    tests-run++
  expect-equals tests-started tests-run

  tests-started++
  with-installed-services
      --priority-a=services.ServiceProvider.PRIORITY-NORMAL
      --priority-b=services.ServiceProvider.PRIORITY-PREFERRED:
    client := PingServiceClient
    client.open
    client.ping
    expect-equals "ping/B" client.name
    tests-run++
  expect-equals tests-started tests-run

  tests-started++
  with-client (PingService.SELECTOR.restrict.allow --name="ping/B"): | client/PingServiceClient |
    expect-equals "ping/B" client.name
    tests-run++
  expect-equals tests-started tests-run

  tests-started++
  with-client (PingService.SELECTOR.restrict.allow --name="ping/B" --major=3): | client/PingServiceClient |
    expect-equals "ping/B" client.name
    tests-run++
  expect-equals tests-started tests-run

  tests-started++
  with-client (PingService.SELECTOR.restrict.allow --name="ping/B" --major=3 --minor=4): | client/PingServiceClient |
    expect-equals "ping/B" client.name
    tests-run++
  expect-equals tests-started tests-run

  tests-started++
  with-client (PingService.SELECTOR.restrict.allow --tag="A"): | client/PingServiceClient |
    expect-equals "ping/A" client.name
    tests-run++
  expect-equals tests-started tests-run

  tests-started++
  with-client (PingService.SELECTOR.restrict.allow --tag="B"): | client/PingServiceClient |
    expect-equals "ping/B" client.name
    tests-run++
  expect-equals tests-started tests-run

  tests-started++
  with-client (PingService.SELECTOR.restrict.allow --tag="!A"): | client/PingServiceClient |
    expect-equals "ping/B" client.name
    tests-run++
  expect-equals tests-started tests-run

  // Look for either the non-exisiting 'nope' tag or B.
  tests-started++
  selector := PingService.SELECTOR.restrict.allow --tags=["nope", "B"]
  with-client selector: | client/PingServiceClient |
    expect-equals "ping/B" client.name
    tests-run++
  expect-equals tests-started tests-run

  tests-started++
  with-client (PingService.SELECTOR.restrict.deny --name="ping/A"): | client/PingServiceClient |
    expect-equals "ping/B" client.name
    tests-run++
  expect-equals tests-started tests-run

  tests-started++
  with-client (PingService.SELECTOR.restrict.deny --tag="A"): | client/PingServiceClient |
    expect-equals "ping/B" client.name
    tests-run++
  expect-equals tests-started tests-run

  tests-started++
  with-client (PingService.SELECTOR.restrict.deny --name="ping/B" --major=3): | client/PingServiceClient |
    expect-equals "ping/A" client.name
    tests-run++
  expect-equals tests-started tests-run

  tests-started++
  with-client (PingService.SELECTOR.restrict.deny --name="ping/B" --major=3 --minor=4): | client/PingServiceClient |
    expect-equals "ping/A" client.name
    tests-run++
  expect-equals tests-started tests-run

  tests-started++
  selector = PingService.SELECTOR.restrict
  selector.allow --name="ping/B" --major=3 --minor=4
  selector.deny --name="ping/B" --major=33 --minor=44
  with-client selector: | client/PingServiceClient |
    expect-equals "ping/B" client.name
    tests-run++
  expect-equals tests-started tests-run

  tests-started++
  selector = PingService.SELECTOR.restrict
  selector.allow --name="ping/B" --major=33 --minor=44
  selector.allow --name="ping/B" --major=3 --minor=4
  selector.allow --name="ping/B" --major=333 --minor=444
  with-client selector: | client/PingServiceClient |
    expect-equals "ping/B" client.name
    tests-run++
  expect-equals tests-started tests-run

  tests-started++
  selector.allow --name="ping/A" --major=11 --minor=22
  selector.allow --name="ping/A" --major=1 --minor=22
  selector.allow --name="ping/A" --major=11 --minor=2
  with-client selector: | client/PingServiceClient |
    expect-equals "ping/B" client.name
    tests-run++
  expect-equals tests-started tests-run

test-negative:
  expect-throw "Cannot disambiguate":
    with-client PingService.SELECTOR: unreachable

  expect-throw "Cannot disambiguate":
    with-client (PingService.SELECTOR.restrict.allow --tag="yada"): unreachable

  expect-throw "Cannot disambiguate":
    with-client (PingService.SELECTOR.restrict.allow --tag="yada"): unreachable

  expect-throw "Cannot disambiguate":
    with-client (PingService.SELECTOR.restrict.deny --name="ping/B" --major=33): unreachable

  expect-throw "Cannot disambiguate":
    with-client (PingService.SELECTOR.restrict.deny --name="ping/B" --major=3 --minor=44): unreachable

  expect-throw "Cannot disambiguate":
    with-client (PingService.SELECTOR.restrict.deny --name="ping/B" --major=33 --minor=44): unreachable

  expect-throw "Cannot disambiguate":
    // Look for either tag B or yada. Both have yada.
    selector := PingService.SELECTOR.restrict.allow --tags=["B", "yada"]
    with-client selector: unreachable

  // Look for anything that doesn't have the non-existing tag 'nope'.
  expect-throw "Cannot disambiguate":
    with-client (PingService.SELECTOR.restrict.deny --tag="nope"): unreachable

  expect-throw "Cannot disambiguate":
    selector := PingService.SELECTOR.restrict
    selector.allow --name="ping/A" --major=11 --minor=22
    selector.allow --name="ping/A" --major=1 --minor=2
    selector.allow --name="ping/A" --major=111 --minor=222
    selector.allow --name="ping/B" --major=33 --minor=44
    selector.allow --name="ping/B" --major=3 --minor=4
    selector.allow --name="ping/B" --major=333 --minor=444
    with-client selector: unreachable

  expect-throw "Cannot find service":
    with-client (PingService.SELECTOR.restrict.deny --tag="yada"): unreachable

  expect-throw "Cannot find service":
    with-client (PingService.SELECTOR.restrict.allow --tag="nope"): unreachable

  expect-throw "Cannot find service":
    // Look for tag B, but not yada.
    selector := PingService.SELECTOR.restrict
    selector.allow --tag="B"
    selector.deny --tag="yada"
    with-client selector: unreachable

  expect-throw "Cannot find service":
    with-client (PingService.SELECTOR.restrict.allow --name="ping/B" --major=33): unreachable

  expect-throw "Cannot find service":
    with-client (PingService.SELECTOR.restrict.allow --name="ping/B" --major=33 --minor=4): unreachable

  expect-throw "Cannot find service":
    with-client (PingService.SELECTOR.restrict.allow --name="ping/B" --major=3 --minor=44): unreachable

test-errors:
  expect-throw "Must have major version to match on minor":
    selector := PingService.SELECTOR.restrict
    selector.allow --name="fusk" --minor=2

  expect-throw "Must have major version to match on minor":
    selector := PingService.SELECTOR.restrict
    selector.deny --name="fusk" --minor=2

  expect-throw "Cannot have multiple entries for the same named version":
    selector := PingService.SELECTOR.restrict
    selector.allow --name="fusk"
    selector.allow --name="fusk" --major=1

  expect-throw "Cannot have multiple entries for the same named version":
    selector := PingService.SELECTOR.restrict
    selector.allow --name="fusk"
    selector.allow --name="fusk" --major=1 --minor=2

  expect-throw "Cannot have multiple entries for the same named version":
    selector := PingService.SELECTOR.restrict
    selector.allow --name="fusk"
    selector.deny --name="fusk"

  expect-throw "Cannot allow and deny the same tag":
    selector := PingService.SELECTOR.restrict
    selector.allow --tag="kuks"
    selector.deny --tag="kuks"

with-client selector/services.ServiceSelector [block]:
  with-installed-services:
    client := PingServiceClient selector
    client.open
    client.ping
    block.call client

with-installed-services --priority-a/int?=null --priority-b/int?=null [block]:
  with-installed-services
      --create-a=(: PingServiceProvider.A --priority=priority-a)
      --create-b=(: PingServiceProvider.B --priority=priority-b)
      block

with-installed-services [--create-a] [--create-b] [block]:
  service-a := create-a.call
  service-a.install
  service-b := create-b.call
  service-b.install

  try:
    block.call
  finally:
    service-a.uninstall
    service-b.uninstall

// ------------------------------------------------------------------

class PingServiceClient extends services.ServiceClient implements PingService:
  constructor selector/services.ServiceSelector=PingService.SELECTOR:
    super selector

  ping -> none:
    invoke_ PingService.PING-INDEX null

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

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == PingService.PING-INDEX: return ping
    unreachable

  ping -> none:
    print "Ping $identifier"
