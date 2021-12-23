// Copyright (C) 2020 Toitware ApS. All rights reserved.

import .utils
import ...tools.snapshot show *
import expect show *
import host.file
import host.directory

WHITELISTED ::= ["expect", "expect_equals", "identical", "expect_not", "expect_not_null"]

main args:
  fold_test_path := directory.realpath "$directory.cwd/../fold_test.toit"

  snap := run args --entry_path=fold_test_path
  program := snap.decode
  methods := extract_methods program [
    "int_int_test",
    "int_float_test",
    "float_int_test",
    "float_float_test",
    "not_test",
    "if_test"
  ]
  methods.do: |name method|
    expect method != null
    method.do_bytecodes: |bytecode bci|
      if bytecode.name == "INVOKE_STATIC":
        target := target_of_invoke_static program method bci
        target_name := target.name
        expect (WHITELISTED.contains target_name)
      else if bytecode.name.starts_with "BRANCH":  // Branches are generated for `not`s which should be optimized out.
        throw "Unreachable (optimized out)"
      else:
        expect (not bytecode.name.starts_with "INVOKE")

  // Make sure that these are the only tests in that file.
  main_method := (extract_methods program ["main"])["main"]
  seen_invocations := {}
  main_method.do_bytecodes: |bytecode bci|
    if bytecode.name == "INVOKE_STATIC":
      target := target_of_invoke_static program main_method bci
      seen_invocations.add target.name
  expect_equals methods.size seen_invocations.size
  seen_invocations.do: expect (methods.contains it)
