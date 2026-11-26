// Copyright (C) 2026 Toit contributors.

// A minimal service shared by the provider and the suite (client).

import system.services

interface EchoService:
  static SELECTOR ::= services.ServiceSelector
      --uuid="5b9c8a8e-2b1a-4c7e-9a3f-0d6c2e1f4a77"
      --major=1
      --minor=0

  echo value/any -> any
  static ECHO-INDEX ::= 0

  add a/int b/int -> int
  static ADD-INDEX ::= 1

class EchoServiceClient extends services.ServiceClient implements EchoService:
  static SELECTOR ::= EchoService.SELECTOR
  constructor selector/services.ServiceSelector=SELECTOR:
    assert: selector.matches SELECTOR
    super selector

  echo value/any -> any:
    return invoke_ EchoService.ECHO-INDEX value

  add a/int b/int -> int:
    return invoke_ EchoService.ADD-INDEX [a, b]

class EchoServiceProvider extends services.ServiceProvider implements services.ServiceHandler:
  calls := 0

  constructor:
    super "echo" --major=1 --minor=0
    provides EchoService.SELECTOR --handler=this

  handle index/int arguments/any --gid/int --client/int -> any:
    calls++
    if index == EchoService.ECHO-INDEX: return arguments
    if index == EchoService.ADD-INDEX: return arguments[0] + arguments[1]
    unreachable
