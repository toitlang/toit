// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import system.services

main:
  service := LogServiceDefinition
  service.install
  logger := LogServiceClient
  logger.log "Hello"
  logger.log "World"
  logger.close
  service.uninstall

// ------------------------------------------------------------------

interface LogService:
  static UUID/string ::= "00e1aca5-4861-4ec6-86e6-eea82936af13"
  static MAJOR/int   ::= 1
  static MINOR/int   ::= 0

  static LOG_INDEX ::= 0
  log message/string -> none

// ------------------------------------------------------------------

class LogServiceClient extends services.ServiceClient implements LogService:
  constructor --open/bool=true:
    super --open=open

  open -> LogServiceClient?:
    return (open_ LogService.UUID LogService.MAJOR LogService.MINOR) and this

  log message/string -> none:
    invoke_ LogService.LOG_INDEX message

// ------------------------------------------------------------------

class LogServiceDefinition extends services.ServiceDefinition implements LogService:
  constructor:
    super "log" --major=1 --minor=0
    provides LogService.UUID LogService.MAJOR LogService.MINOR

  handle pid/int client/int index/int arguments/any -> any:
    if index == LogService.LOG_INDEX: return log arguments
    unreachable

  log message/string -> none:
    print "$(%08d Time.monotonic_us): $message"
