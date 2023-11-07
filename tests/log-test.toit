// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import log
import system.api.print
import .services-print-test show PrintServiceProvider
import expect show *

service ::= PrintServiceProvider

expect output/string? [block]:
  expect-equals 0 service.messages.size
  try:
    block.call
  finally:
    result := service.messages
    if output:
      expect-equals 1 result.size
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

  service.uninstall
