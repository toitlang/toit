// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .utils
import ...tools.snapshot show *
import expect show *
import host.file
import host.directory

check-0-2 program method:
  seen-array-constructor-call := false
  method.do-bytecodes: |bytecode bci|
    if bytecode.name == "INVOKE_STATIC":
      target := target-of-invoke-static program method bci
      if target.name == "constructor" or target.name == "create-array_":
        expect-not seen-array-constructor-call
        seen-array-constructor-call = true

  expect seen-array-constructor-call

check-1 program method:
  method.do-bytecodes: |bytecode bci|
    if bytecode.name == "INVOKE_STATIC":
      target := target-of-invoke-static program method bci
      expect-equals "lambda_" target.name

main args:
  fold-test-path := directory.realpath "$directory.cwd/../lambda6-test.toit"

  snap := run args --entry-path=fold-test-path
  program := snap.decode
  methods := extract-methods program [
    "create-lambda0",
    "create-lambda1",
    "create-lambda2",
  ]

  check-0-2 program methods["create-lambda0"]
  check-1   program methods["create-lambda1"]
  check-0-2 program methods["create-lambda2"]
