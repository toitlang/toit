// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import log
import ..tools.logging show log_format

import expect show *

class TestTarget extends log.DefaultTarget:
  expected_ := null

  log names level message tags -> none:
    out := log_format names level message tags --with_timestamp=false
    expect_equals expected_ out

target_ := TestTarget

expect output [block]:
  target_.expected_ = output
  block.call log.default_

main:
  log.default_ = log.Logger log.DEBUG_LEVEL target_

  expect "DEBUG: hest": log.debug "hest"
  expect "DEBUG: hest {fisk: ko}": log.debug "hest" --tags={"fisk": "ko"}
  expect "INFO: hest {fisk: ko, age: 42}": log.info "hest" --tags={"fisk": "ko", "age": 42}


  logger := log.Logger log.INFO_LEVEL target_
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
