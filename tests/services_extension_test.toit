// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system.services
import expect

interface MyService:
  static SELECTOR ::= services.ServiceSelector
      --uuid="867f200f-9311-48a5-83a2-1033597b8961"
      --major=0
      --minor=1

  foo -> int
  static FOO_INDEX ::= 0

  bar x/int -> int
  static BAR_INDEX ::= 1

interface MyServiceExtended extends MyService:
  static SELECTOR ::= services.ServiceSelector
      --uuid="711e9020-69cd-4e86-84c7-6e0a92a26fa6"
      --major=1
      --minor=2

  baz x/string -> none
  static BAZ_INDEX ::= 100

main:
  spawn:: run_server
  sleep --ms=50
  run_client

run_server:
  service := MyServiceProvider
  service.install
  service.uninstall --wait

run_client:
  service := MyServiceClient
  service.open
  expect.expect_equals "service:myservice/extended@1.2.3" "$service"
  expect.expect_equals 42 service.foo
  expect.expect_equals 16 (service.bar 7)
  expect.expect_equals 40 (service.bar 19)

  extended := MyServiceExtendedClient
  extended.open
  expect.expect_equals "service:myservice/extended@1.2.3" "$extended"
  extended.baz "Hello, World!"

// ------------------------------------------------------------------

class MyServiceClient extends services.ServiceClient implements MyService:
  static SELECTOR ::= MyService.SELECTOR
  constructor selector/services.ServiceSelector=SELECTOR:
    assert: selector.matches SELECTOR
    super selector

  foo -> int:
    return invoke_ MyService.FOO_INDEX null

  bar x/int -> int:
    return invoke_ MyService.BAR_INDEX x

class MyServiceExtendedClient extends MyServiceClient implements MyServiceExtended:
  static SELECTOR ::= MyServiceExtended.SELECTOR
  constructor selector/services.ServiceSelector=SELECTOR:
    assert: selector.matches SELECTOR
    super selector

  baz x/string -> none:
    invoke_ MyServiceExtended.BAZ_INDEX x

// ------------------------------------------------------------------

class MyServiceProvider extends services.ServiceProvider
    implements MyServiceExtended services.ServiceHandlerNew:
  constructor:
    super "myservice/extended" --major=1 --minor=2 --patch=3
    provides MyService.SELECTOR --handler=this --new
    provides MyServiceExtended.SELECTOR --handler=this --new

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == MyService.FOO_INDEX: return foo
    if index == MyService.BAR_INDEX: return bar arguments
    if index == MyServiceExtended.BAZ_INDEX: return baz arguments
    unreachable

  foo -> int:
    return 42

  bar x/int -> int:
    return (x + 1) * 2

  baz x/string -> none:
    expect.expect_equals "Hello, World!" x
