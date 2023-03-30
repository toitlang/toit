// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system.services
import expect

interface SimpleService:
  static SELECTOR ::= services.ServiceSelector
      --uuid="10660fd6-3df8-4123-ac6e-e295484a4891"
      --major=1
      --minor=2

  log message/string -> none
  static LOG_INDEX ::= 0

main:
  test_logging
  test_logging --separate_process
  test_illegal_name
  test_versions
  test_uninstall

test_logging --separate_process/bool=false:
  service := SimpleServiceProvider
  service.install
  if separate_process:
    spawn:: test_hello
  else:
    test_hello --close
  service.uninstall --wait

test_illegal_name:
  service := SimpleServiceProvider
  service.install

  expect.expect_throw "Cannot find service":
    (FlexibleServiceClient --uuid="").open
  expect.expect_null
    (FlexibleServiceClient --uuid="").open --if_absent=: null

  expect.expect_throw "Cannot find service":
    (FlexibleServiceClient --uuid="logs").open
  expect.expect_null
    (FlexibleServiceClient --uuid="logs").open --if_absent=: null

  expect.expect_throw "Cannot find service":
    (FlexibleServiceClient --uuid="log.illegal").open
  expect.expect_null
    (FlexibleServiceClient --uuid="log.illegal").open --if_absent=: null

  service.uninstall

test_versions:
  service := SimpleServiceProvider
  service.install

  uuid := SimpleService.SELECTOR.uuid
  expect.expect_throw "service:log@1.2.5 does not provide service:$uuid@0.x":
    (FlexibleServiceClient --major=0).open
  expect.expect_throw "service:log@1.2.5 does not provide service:$uuid@0.x":
    (FlexibleServiceClient --major=0).open --if_absent=: null

  expect.expect_throw "service:log@1.2.5 does not provide service:$uuid@2.x":
    (FlexibleServiceClient --major=2).open
  expect.expect_throw "service:log@1.2.5 does not provide service:$uuid@2.x":
    (FlexibleServiceClient --major=2).open --if_absent=: null

  expect.expect_throw "service:log@1.2.5 does not provide service:$uuid@1.3.x":
    (FlexibleServiceClient --minor=3).open
  expect.expect_throw "service:log@1.2.5 does not provide service:$uuid@1.3.x":
    (FlexibleServiceClient --minor=3).open --if_absent=: null

  client := FlexibleServiceClient --major=1 --minor=1
  client.open
  expect.expect_equals 1 client.major
  expect.expect_equals 2 client.minor
  expect.expect_equals 5 client.patch
  client.close
  service.uninstall --wait

test_uninstall:
  service := SimpleServiceProvider
  service.install
  test_hello --no-close
  logger := SimpleServiceClient
  logger.open
  service.uninstall
  exception := catch: logger.log "Don't let me do this!"
  expect.expect_equals "key not found" exception

test_hello --close=false:
  logger := SimpleServiceClient
  logger.open
  logger.log "Hello!"
  if close: logger.close

// ------------------------------------------------------------------

class SimpleServiceClient extends services.ServiceClient implements SimpleService:
  static SELECTOR ::= SimpleService.SELECTOR
  constructor selector/services.ServiceSelector=SELECTOR:
    assert: selector.matches SELECTOR
    super selector

  log message/string -> none:
    invoke_ SimpleService.LOG_INDEX message

class FlexibleServiceClient extends services.ServiceClient:
  constructor
      --uuid/string=SimpleService.SELECTOR.uuid
      --major/int=SimpleService.SELECTOR.major
      --minor/int=SimpleService.SELECTOR.minor:
    modified := services.ServiceSelector
        --uuid=uuid
        --major=major
        --minor=minor
    super modified

// ------------------------------------------------------------------

class SimpleServiceProvider extends services.ServiceProvider
    implements SimpleService services.ServiceHandlerNew:
  constructor:
    super "log" --major=1 --minor=2 --patch=5
    provides SimpleService.SELECTOR --handler=this --new

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == SimpleService.LOG_INDEX: return log arguments
    unreachable

  log message/string -> none:
    print "$(Time.now.local): $message"
