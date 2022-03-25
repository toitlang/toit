// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system.services
import expect

interface MyService:
  static NAME/string ::= "myservice"
  static MAJOR/int   ::= 0
  static MINOR/int   ::= 1

  static FOO_INDEX ::= 0
  foo -> int

  static BAR_INDEX ::= 1
  bar x/int -> int

interface MyServiceExtended extends MyService:
  static NAME/string ::= "myservice/extended"
  static MAJOR/int   ::= 1
  static MINOR/int   ::= 2

  static BAZ_INDEX ::= 100
  baz x/string -> none

main:
  spawn:: run_server
  sleep --ms=50
  run_client

run_server:
  service := MyServiceDefinition
  service.install
  service.wait

run_client:
  service/MyService := MyServiceClient.lookup
  expect.expect_equals "service:myservice/extended@1.2.3" "$service"
  expect.expect_equals 42 service.foo
  expect.expect_equals 16 (service.bar 7)
  expect.expect_equals 40 (service.bar 19)

  extended/MyServiceExtended := MyServiceExtendedClient.lookup
  expect.expect_equals "service:myservice/extended@1.2.3" "$extended"
  extended.baz "Hello, World!"

// ------------------------------------------------------------------

class MyServiceClient extends services.ServiceClient implements MyService:
  constructor.lookup name=MyService.NAME major=MyService.MAJOR minor=MyService.MINOR:
    super.lookup name major minor

  foo -> int:
    return invoke_ MyService.FOO_INDEX null

  bar x/int -> int:
    return invoke_ MyService.BAR_INDEX x

class MyServiceExtendedClient extends MyServiceClient implements MyServiceExtended:
  constructor.lookup name=MyServiceExtended.NAME major=MyServiceExtended.MAJOR minor=MyServiceExtended.MINOR:
    super.lookup name major minor

  baz x/string -> none:
    invoke_ MyServiceExtended.BAZ_INDEX x

// ------------------------------------------------------------------

class MyServiceDefinition extends services.ServiceDefinition implements MyServiceExtended:
  constructor:
    super MyServiceExtended.NAME
        --major=MyServiceExtended.MAJOR
        --minor=MyServiceExtended.MINOR
        --patch=3
    alias MyService.NAME --major=MyService.MAJOR --minor=MyService.MINOR

  handle index/int arguments/any -> any:
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
