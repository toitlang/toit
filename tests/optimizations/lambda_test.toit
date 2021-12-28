// Copyright (C) 2020 Toitware ApS. All rights reserved.

import .utils
import ...tools.snapshot show *
import expect show *
import host.file
import host.directory

check_0_2 program method:
  seen_array_constructor_call := false
  method.do_bytecodes: |bytecode bci|
    if bytecode.name == "INVOKE_STATIC":
      target := target_of_invoke_static program method bci
      if target.name == "constructor" or target.name == "create_array_":
        expect_not seen_array_constructor_call
        seen_array_constructor_call = true

  expect seen_array_constructor_call

check_1 program method:
  method.do_bytecodes: |bytecode bci|
    if bytecode.name == "INVOKE_STATIC":
      target := target_of_invoke_static program method bci
      expect_equals "lambda_" target.name

main args:
  fold_test_path := directory.realpath "$directory.cwd/../lambda6_test.toit"

  snap := run args --entry_path=fold_test_path
  program := snap.decode
  methods := extract_methods program [
    "create_lambda0",
    "create_lambda1",
    "create_lambda2",
  ]

  check_0_2 program methods["create_lambda0"]
  check_1   program methods["create_lambda1"]
  check_0_2 program methods["create_lambda2"]
