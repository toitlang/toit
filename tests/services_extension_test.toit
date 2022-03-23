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

  static UNINSTALL_INDEX ::= 2
  uninstall -> none

interface MyServiceHest extends MyService:
  static NAME/string ::= "myservice/hest"
  static MAJOR/int   ::= 1
  static MINOR/int   ::= 1

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
  print "myservice = $service"
  print service.foo
  print (service.bar 7)
  print (service.bar 19)

  hest/MyServiceHest := MyServiceHestClient.lookup
  print "myservice.hest = $hest"
  hest.baz "Hello, World!"

  iterations := 100_000
  elapsed := Duration.of:
    iterations.repeat: service.bar it
  print "Time per service call = $(elapsed / iterations)"


// ------------------------------------------------------------------

class MyServiceClient extends services.ServiceClient implements MyService:
  constructor.lookup name=MyService.NAME major=MyService.MAJOR minor=MyService.MINOR:
    super.lookup name major minor

  foo -> int:
    return invoke_ MyService.FOO_INDEX null

  bar x/int -> int:
    return invoke_ MyService.BAR_INDEX x

  uninstall -> none:
    invoke_ MyService.UNINSTALL_INDEX null

class MyServiceHestClient extends MyServiceClient implements MyServiceHest:
  constructor.lookup name=MyServiceHest.NAME major=MyServiceHest.MAJOR minor=MyServiceHest.MINOR:
    super.lookup name major minor

  baz x/string -> none:
    invoke_ MyServiceHest.BAZ_INDEX x

// ------------------------------------------------------------------

class MyServiceDefinition extends services.ServiceDefinition implements MyServiceHest:
  constructor:
    super MyServiceHest.NAME --major=MyServiceHest.MAJOR --minor=MyServiceHest.MINOR --patch=3
    alias MyService.NAME --major=MyService.MAJOR --minor=MyService.MINOR

  handle index/int arguments/any -> any:
    if index == MyService.FOO_INDEX: return foo
    if index == MyService.BAR_INDEX: return bar arguments
    if index == MyService.UNINSTALL_INDEX: return uninstall
    if index == MyServiceHest.BAZ_INDEX: return baz arguments
    unreachable

  foo -> int:
    return 42

  bar x/int -> int:
    return (x + 1) * 2

  baz x/string -> none:
    print "baz: $x"
