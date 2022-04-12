// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import log
import expect

import system.services show ServiceDefinition
import system.api.logging show LoggingService

service ::= LoggingServiceDefinition

expect_log level/int message/string names/List? keys/List? values/List? [block]:
  expect.expect_equals 0 service.logs.size
  try:
    block.call
  finally:
    result := service.logs
    expect.expect_equals 1 result.size
    log_level/int := result.first[0]
    expect.expect_equals (log.level_name level) (log.level_name log_level)
    log_message/string := result.first[1]
    expect.expect_equals message log_message
    log_names/List? := result.first[2]
    if names:
      expect.expect_list_equals names log_names
    else:
      expect.expect_null log_names
    log_keys/List? := result.first[3]
    if keys:
      expect.expect_list_equals keys log_keys
    else:
      expect.expect_null log_keys
    log_values/List? := result.first[4]
    if values:
      expect.expect_list_equals values log_values
    else:
      expect.expect_null log_values

main:
  service.install
  [ log.DEBUG_LEVEL, log.WARN_LEVEL, log.INFO_LEVEL, log.ERROR_LEVEL ].do: | level/int |
    expect_log level "fisk" null null null:
      log.log level "fisk"
  expect_log log.WARN_LEVEL "hest" ["gerdt"] null null:
    logger := log.default.with_name "gerdt"
    logger.warn "hest"
  expect_log log.WARN_LEVEL "hest" ["gerdt"] ["mums"] ["42"]:
    logger := log.default.with_name "gerdt"
    logger.warn "hest" --tags={"mums": 42}
  expect_log log.ERROR_LEVEL "gris" null ["mums"] ["43"]:
    logger := log.default.with_tag "mums" 43
    logger.error "gris"
  expect_log log.ERROR_LEVEL "gris" null ["mums", "jumbo"] ["43", "99"]:
    logger := log.default.with_tag "mums" 43
    logger.error "gris" --tags={"jumbo": 99}
  expect_log log.ERROR_LEVEL "gris" null ["mums"] ["99"]:
    logger := log.default.with_tag "mums" 43
    logger.error "gris" --tags={"mums": 99}
  expect_log log.ERROR_LEVEL "gris" ["grums"] ["mums"] ["99"]:
    logger := (log.default.with_tag "mums" 43).with_name "grums"
    logger.error "gris" --tags={"mums": 99}
  service.uninstall
  // TODO(kasper): How do we handle services that come and go
  // from the client side?
  expect.expect_throw "key not found": log.debug "Oh no"

class LoggingServiceDefinition extends ServiceDefinition implements LoggingService:
  logs_/List := []

  constructor:
    super LoggingService.NAME --major=LoggingService.MAJOR --minor=LoggingService.MINOR

  handle pid/int client/int index/int arguments/any -> any:
    if index == LoggingService.LOG_INDEX: return logs_.add arguments
    unreachable

  logs -> List:
    result := logs_
    logs_ = []
    return result

  log level/int message/string names/List? keys/List? values/List? -> none:
    unreachable  // Unused.
