// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import log
import system.api.print
import .services-print-test show PrintServiceProvider
import expect show *

service ::= PrintServiceProvider

expect output/string? --with-timestamp=false [block]:
  expect-equals 0 service.messages.size
  try:
    block.call
  finally:
    result := service.messages
    if output:
      expect-equals 1 result.size
      if with-timestamp:
        tmp := result.first
        time := tmp[0..tmp.index-of " "]
        rest := tmp[(tmp.index-of " ") + 1..]
        expect-no-throw : int.parse time
        expect-equals output rest
      else:
        expect-equals output result.first
    else:
      expect-equals 0 result.size

main:
  service.install

  expect "DEBUG: hest": log.debug "hest"
  expect "DEBUG: hest {fisk: ko}": log.debug "hest" --tags={"fisk": "ko"}
  expect "INFO: hest {fisk: ko, age: 42}": log.info "hest" --tags={"fisk": "ko", "age": 42}

  logger := log.Logger log.INFO-LEVEL log.DefaultTarget
  expect null: logger.debug "hest"
  expect "INFO: hest": log.info "hest"
  expect "WARN: hest": log.warn "hest"
  expect "ERROR: hest": log.error "hest"
  expect-equals
    "FATAL"
    catch: expect "FATAL: hest": log.fatal "hest"

  // An ERROR logger stacked on an INFO logger makes an ERROR logger.
  error-logger := logger.with-level log.ERROR-LEVEL
  expect null: error-logger.info "ignore this info"
  expect "ERROR: error!": error-logger.error "error!"

  // A DEBUG logger stacked on an INFO logger makes an INFO logger.
  debug-logger := logger.with-level log.DEBUG-LEVEL
  expect null: error-logger.debug "ignore this info"
  expect "INFO: info!": debug-logger.info "info!"

  lue-logger := log.default_.with-name "42"
  expect "[42] INFO: hest {fisk: ko, age: 42}": lue-logger.info "hest" --tags={"fisk": "ko", "age": 42}

  hv-logger := lue-logger.with-name "103"
  expect "[42.103] INFO: hest {fisk: ko, age: 42}": hv-logger.info "hest" --tags={"fisk": "ko", "age": 42}
  expect "[42.103] INFO: hest {fisk: ko, age: 42}": hv-logger.info "hest" --tags={"fisk": "ko", "age": 42}

  gog-magog-logger := hv-logger.with-tag "gog" "magog"
  expect "[42.103] INFO: hest {gog: magog, fisk: ko, age: 42}": gog-magog-logger.info "hest" --tags={"fisk": "ko", "age": 42}

  time-logger := logger.with-timestamp
  expect "INFO: hest" --with-timestamp: time-logger.info "hest"

  with-logger := logger.with --level=log.ERROR-LEVEL --name="42"
  expect null: with-logger.info "hest"
  expect "[42] ERROR: hest": with-logger.error "hest"
  with-logger = with-logger.with --name="81" --tags={"fisk": "ko"}
  expect "[42.81] ERROR: pony {fisk: ko}": with-logger.error "pony"
  with-logger = with-logger.with --timestamp
  expect "[42.81] ERROR: pony {fisk: ko}" --with-timestamp: with-logger.error "pony"

  service.uninstall
