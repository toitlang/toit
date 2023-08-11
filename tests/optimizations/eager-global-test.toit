// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .utils
import ...tools.snapshot show *
import expect show *
import host.file
import host.directory

check-eager-lazy method/ToitMethod --eager/bool:
  expect method != null
  seen-load-global := false
  method.do-bytecodes: |bytecode bci|
    if bytecode.name == "LOAD_GLOBAL_VAR" or bytecode.name == "LOAD_GLOBAL_VAR_WIDE":
      expect eager
      seen-load-global = true
    else if bytecode.name == "LOAD_GLOBAL_VAR_LAZY" or bytecode.name == "LOAD_GLOBAL_VAR_LAZY_WIDE":
      expect (not eager)
      seen-load-global = true
  expect seen-load-global

main args:
  eager-global-test-path := directory.realpath "$directory.cwd/../eager-global-test.toit"

  snap := run args --entry-path=eager-global-test-path
  program := snap.decode
  methods := extract-methods program [ "eager-test", "lazy-test" ]
  print methods
  check-eager-lazy --eager methods["eager-test"]
  check-eager-lazy --no-eager methods["lazy-test"]
