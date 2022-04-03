// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import log
import system.api.print
import .services_print_test show PrintServiceDefinition
import expect show *

service/PrintServiceDefinition ::= PrintServiceDefinition

expect output/string? [block]:
  expect_equals 0 service.messages.size
  try:
    block.call
  finally:
    result := service.messages
    if output:
      expect_equals 1 result.size
      expect_equals output result.first
    else:
      expect_equals 0 result.size

main:
  service.install

  expect "DEBUG: hest": log.debug "hest"
  expect "DEBUG: hest {fisk: ko}": log.debug "hest" --tags={"fisk": "ko"}
  expect "INFO: hest {fisk: ko, age: 42}": log.info "hest" --tags={"fisk": "ko", "age": 42}

  logger := log.Logger log.INFO_LEVEL log.DefaultTarget
  expect null: logger.debug "hest"
  expect "INFO: hest": log.info "hest"
  expect "WARN: hest": log.warn "hest"
  expect "ERROR: hest": log.error "hest"
  expect_equals
    "FATAL"
    catch: expect "FATAL: hest": log.fatal "hest"

  // An ERROR logger stacked on an INFO logger makes an ERROR logger.
  error_logger := logger.with_level log.ERROR_LEVEL
  expect null: error_logger.info "ignore this info"
  expect "ERROR: error!": error_logger.error "error!"

  // A DEBUG logger stacked on an INFO logger makes an INFO logger.
  debug_logger := logger.with_level log.DEBUG_LEVEL
  expect null: error_logger.debug "ignore this info"
  expect "INFO: info!": debug_logger.info "info!"

  lue_logger := log.default_.with_name "42"
  expect "[42] INFO: hest {fisk: ko, age: 42}": lue_logger.info "hest" --tags={"fisk": "ko", "age": 42}

  hv_logger := lue_logger.with_name "103"
  expect "[42.103] INFO: hest {fisk: ko, age: 42}": hv_logger.info "hest" --tags={"fisk": "ko", "age": 42}
  expect "[42.103] INFO: hest {fisk: ko, age: 42}": hv_logger.info "hest" --tags={"fisk": "ko", "age": 42}

  gog_magog_logger := hv_logger.with_tag "gog" "magog"
  expect "[42.103] INFO: hest {gog: magog, fisk: ko, age: 42}": gog_magog_logger.info "hest" --tags={"fisk": "ko", "age": 42}

  service.uninstall
