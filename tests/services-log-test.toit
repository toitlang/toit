// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import log
import expect

import system.services show ServiceProvider ServiceHandler
import system.api.log show LogService

service ::= LogServiceProvider

expect-log level/int message/string names/List? keys/List? values/List? [block]:
  expect.expect-equals 0 service.logs.size
  try:
    block.call
  finally:
    result := service.logs
    expect.expect-equals 1 result.size
    log-level/int := result.first[0]
    expect.expect-equals (log.level-name level) (log.level-name log-level)
    log-message/string := result.first[1]
    expect.expect-equals message log-message
    log-names/List? := result.first[2]
    if names:
      expect.expect-list-equals names log-names
    else:
      expect.expect-null log-names
    log-keys/List? := result.first[3]
    if keys:
      expect.expect-list-equals keys log-keys
    else:
      expect.expect-null log-keys
    log-values/List? := result.first[4]
    if values:
      expect.expect-list-equals values log-values
    else:
      expect.expect-null log-values

main:
  service.install
  [ log.DEBUG-LEVEL, log.WARN-LEVEL, log.INFO-LEVEL, log.ERROR-LEVEL ].do: | level/int |
    expect-log level "fisk" null null null:
      log.log level "fisk"
  expect-log log.WARN-LEVEL "hest" ["gerdt"] null null:
    logger := log.default.with-name "gerdt"
    logger.warn "hest"
  expect-log log.WARN-LEVEL "hest" ["gerdt"] ["mums"] ["42"]:
    logger := log.default.with-name "gerdt"
    logger.warn "hest" --tags={"mums": 42}
  expect-log log.ERROR-LEVEL "gris" null ["mums"] ["43"]:
    logger := log.default.with-tag "mums" 43
    logger.error "gris"
  expect-log log.ERROR-LEVEL "gris" null ["mums", "jumbo"] ["43", "99"]:
    logger := log.default.with-tag "mums" 43
    logger.error "gris" --tags={"jumbo": 99}
  expect-log log.ERROR-LEVEL "gris" null ["mums"] ["99"]:
    logger := log.default.with-tag "mums" 43
    logger.error "gris" --tags={"mums": 99}
  expect-log log.ERROR-LEVEL "gris" ["grums"] ["mums"] ["99"]:
    logger := (log.default.with-tag "mums" 43).with-name "grums"
    logger.error "gris" --tags={"mums": 99}
  service.uninstall
  // TODO(kasper): How do we handle services that come and go
  // from the client side?
  expect.expect-throw "HANDLER_NOT_FOUND": log.debug "Oh no"

class LogServiceProvider extends ServiceProvider
    implements LogService ServiceHandler:
  logs_/List := []

  constructor:
    super "system/log/test" --major=1 --minor=2
    provides LogService.SELECTOR --handler=this

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == LogService.LOG-INDEX: return logs_.add arguments
    unreachable

  logs -> List:
    result := logs_
    logs_ = []
    return result

  log level/int message/string names/List? keys/List? values/List? -> none:
    unreachable  // Unused.
