// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system.services
import expect

interface LogService:
  static NAME/string ::= "log"
  static MAJOR/int   ::= 0
  static MINOR/int   ::= 1

  static LOG_INDEX ::= 0
  log message/string -> none

main:
  service := LogServiceDefinition
  service.install
  spawn:: run_client
  service.wait

run_client:
  logger := LogServiceClient.lookup
  logger.log "Hello!"

// ------------------------------------------------------------------

class LogServiceClient extends services.ServiceClient implements LogService:
  constructor.lookup name=LogService.NAME major=LogService.MAJOR minor=LogService.MINOR:
    super.lookup name major minor

  log message/string -> none:
    invoke_ LogService.LOG_INDEX message

// ------------------------------------------------------------------

class LogServiceDefinition extends services.ServiceDefinition implements LogService:
  constructor:
    super LogService.NAME --major=LogService.MAJOR --minor=LogService.MINOR --patch=0

  handle index/int arguments/any -> any:
    if index == LogService.LOG_INDEX: return log arguments
    unreachable

  log message/string -> none:
    print "$(Time.now.local): $message"
