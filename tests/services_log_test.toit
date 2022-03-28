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
  expect.expect_throw "Cannot find service:":
    LogServiceClient.lookup ""
  expect.expect_throw "Cannot find service:logs":
    LogServiceClient.lookup "logs"
  expect.expect_throw "Cannot find service:log.illegal":
    LogServiceClient.lookup "log.illegal"
  service.uninstall

test_versions:
  service := LogServiceDefinition
  service.install
  expect.expect_throw "Cannot find service:log@0.x, found service:log@1.2.5":
    LogServiceClient.lookup LogService.NAME 0
  expect.expect_throw "Cannot find service:log@2.x, found service:log@1.2.5":
    LogServiceClient.lookup LogService.NAME 2
  expect.expect_throw "Cannot find service:log@1.3.x, found service:log@1.2.5":
    LogServiceClient.lookup LogService.NAME 1 3

  client := LogServiceClient.lookup LogService.NAME 1 1
  expect.expect_equals 1 client.major
  expect.expect_equals 2 client.minor
  expect.expect_equals 5 client.patch
  client.close
  service.wait

test_uninstall:
  service := LogServiceDefinition
  service.install
  test_hello --no-close
  logger := LogServiceClient.lookup
  service.uninstall
  exception := catch: logger.log "Don't let me do this!"
  expect.expect (exception.starts_with "No such procedure registered:")

test_hello --close=false:
  logger := LogServiceClient.lookup
  logger.log "Hello!"
  if close: logger.close

// ------------------------------------------------------------------

class LogServiceClient extends services.ServiceClient implements LogService:
  constructor.lookup name=LogService.NAME major=LogService.MAJOR minor=LogService.MINOR:
    super.lookup name major minor

  log message/string -> none:
    invoke_ LogService.LOG_INDEX message

// ------------------------------------------------------------------

class LogServiceDefinition extends services.ServiceDefinition implements LogService:
  constructor:
    super LogService.NAME --major=LogService.MAJOR --minor=LogService.MINOR --patch=5

  handle client/int index/int arguments/any -> any:
    if index == LogService.LOG_INDEX: return log arguments
    unreachable

  log message/string -> none:
    print "$(Time.now.local): $message"
