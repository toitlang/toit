// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system.services
import expect

interface LogService:
  static NAME/string ::= "log"
  static MAJOR/int   ::= 1
  static MINOR/int   ::= 2

  static LOG_INDEX ::= 0
  log message/string -> none

main:
  test_logging
  test_logging --separate_process
  test_illegal_name
  test_versions
  test_uninstall

test_logging --separate_process/bool=false:
  service := LogServiceDefinition
  service.install
  if separate_process:
    spawn:: test_hello
  else:
    test_hello --close
  service.wait

test_illegal_name:
  service := LogServiceDefinition
  service.install

  expect.expect_throw "Cannot find service":
    FlexibleServiceClient ""
  expect.expect_null
    (FlexibleServiceClient "" --no-open).open

  expect.expect_throw "Cannot find service":
    FlexibleServiceClient "logs"
  expect.expect_null
    (FlexibleServiceClient "logs" --no-open).open

  expect.expect_throw "Cannot find service":
    FlexibleServiceClient "log.illegal"
  expect.expect_null
    (FlexibleServiceClient "log.illegal" --no-open).open

  service.uninstall

test_versions:
  service := LogServiceDefinition
  service.install

  expect.expect_throw "Cannot find service:log@0.x, found service:log@1.2.5":
    FlexibleServiceClient LogService.NAME 0
  expect.expect_no_throw:
    (FlexibleServiceClient LogService.NAME 0 --no-open)
  expect.expect_throw "Cannot find service:log@0.x, found service:log@1.2.5":
    (FlexibleServiceClient LogService.NAME 0 --no-open).open

  expect.expect_throw "Cannot find service:log@2.x, found service:log@1.2.5":
    FlexibleServiceClient LogService.NAME 2
  expect.expect_no_throw:
    (FlexibleServiceClient LogService.NAME 2 --no-open)
  expect.expect_throw "Cannot find service:log@2.x, found service:log@1.2.5":
    (FlexibleServiceClient LogService.NAME 2 --no-open).open

  expect.expect_throw "Cannot find service:log@1.3.x, found service:log@1.2.5":
    FlexibleServiceClient LogService.NAME 1 3
  expect.expect_no_throw:
    (FlexibleServiceClient LogService.NAME 1 3 --no-open)
  expect.expect_throw "Cannot find service:log@1.3.x, found service:log@1.2.5":
    (FlexibleServiceClient LogService.NAME 1 3 --no-open).open

  client := FlexibleServiceClient LogService.NAME 1 1
  expect.expect_equals 1 client.major
  expect.expect_equals 2 client.minor
  expect.expect_equals 5 client.patch
  client.close
  service.wait

test_uninstall:
  service := LogServiceDefinition
  service.install
  test_hello --no-close
  logger := LogServiceClient
  service.uninstall
  exception := catch: logger.log "Don't let me do this!"
  expect.expect_equals "key not found" exception

test_hello --close=false:
  logger := LogServiceClient
  logger.log "Hello!"
  if close: logger.close

// ------------------------------------------------------------------

class LogServiceClient extends services.ServiceClient implements LogService:
  constructor --open/bool=true:
    super --open=open

  open -> LogServiceClient?:
    return (open_ LogService.NAME LogService.MAJOR LogService.MINOR) and this

  log message/string -> none:
    invoke_ LogService.LOG_INDEX message

class FlexibleServiceClient extends services.ServiceClient:
  name_/string ::= ?
  major_/int ::= ?
  minor_/int ::= ?

  constructor .name_/string=LogService.NAME .major_/int=LogService.MAJOR .minor_/int=LogService.MINOR --open/bool=true:
    super --open=open

  open -> FlexibleServiceClient?:
    return (open_ name_ major_ minor_) and this

// ------------------------------------------------------------------

class LogServiceDefinition extends services.ServiceDefinition implements LogService:
  constructor:
    super LogService.NAME --major=LogService.MAJOR --minor=LogService.MINOR --patch=5

  handle pid/int client/int index/int arguments/any -> any:
    if index == LogService.LOG_INDEX: return log arguments
    unreachable

  log message/string -> none:
    print "$(Time.now.local): $message"
