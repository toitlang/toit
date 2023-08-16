// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import system.services

// This example illustrates how to define and use a simple logging
// service across two processes.
//
// See https://github.com/toitlang/toit/discussions/869 for more
// details on how the service framework work.

main:
  spawn::
    service := LogServiceProvider
    service.install
    service.uninstall --wait  // Wait until last client closes.

  logger := LogServiceClient
  logger.open
  logger.log "Hello"
  logger.log "World"
  logger.close

// ------------------------------------------------------------------

interface LogService:
  static SELECTOR ::= services.ServiceSelector
      --uuid="00e1aca5-4861-4ec6-86e6-eea82936af13"
      --major=1
      --minor=0

  log message/string -> none
  static LOG-INDEX ::= 0

// ------------------------------------------------------------------

class LogServiceClient extends services.ServiceClient implements LogService:
  static SELECTOR ::= LogService.SELECTOR
  constructor selector/services.ServiceSelector=SELECTOR:
    assert: selector.matches SELECTOR
    super selector

  log message/string -> none:
    invoke_ LogService.LOG-INDEX message

// ------------------------------------------------------------------

class LogServiceProvider extends services.ServiceProvider
    implements LogService services.ServiceHandler:
  constructor:
    super "log" --major=1 --minor=0
    provides LogService.SELECTOR --handler=this

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == LogService.LOG-INDEX: return log arguments
    unreachable

  log message/string -> none:
    print "$(%08d Time.monotonic-us): $message"
