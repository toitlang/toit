// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .utils
import ...tools.snapshot show *
import expect show *
import host.file
import host.directory

check_eager_lazy method/ToitMethod --eager/bool:
  expect method != null
  seen_load_global := false
  method.do_bytecodes: |bytecode bci|
    if bytecode.name == "LOAD_GLOBAL_VAR" or bytecode.name == "LOAD_GLOBAL_VAR_WIDE":
      expect eager
      seen_load_global = true
    else if bytecode.name == "LOAD_GLOBAL_VAR_LAZY" or bytecode.name == "LOAD_GLOBAL_VAR_LAZY_WIDE":
      expect (not eager)
      seen_load_global = true
  expect seen_load_global

main args:
  eager_global_test_path := directory.realpath "$directory.cwd/../eager_global_test.toit"

  snap := run args --entry_path=eager_global_test_path
  program := snap.decode
  methods := extract_methods program [ "eager_test", "lazy_test" ]
  debug methods
  check_eager_lazy --eager methods["eager_test"]
  check_eager_lazy --no-eager methods["lazy_test"]
