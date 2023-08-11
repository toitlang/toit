// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .utils
import ...tools.snapshot show *
import expect show *
import host.file
import host.directory

WHITELISTED ::= ["expect", "expect-equals", "identical", "expect-not", "expect-not-null"]

main args:
  fold-test-path := directory.realpath "$directory.cwd/../fold-test.toit"

  snap := run args --entry-path=fold-test-path
  program := snap.decode
  methods := extract-methods program [
    "int-int-test",
    "int-float-test",
    "float-int-test",
    "float-float-test",
    "not-test",
    "if-test"
  ]
  methods.do: |name method|
    expect method != null
    method.do-bytecodes: |bytecode bci|
      if bytecode.name == "INVOKE_STATIC":
        target := target-of-invoke-static program method bci
        target-name := target.name
        expect (WHITELISTED.contains target-name)
      else if bytecode.name.starts-with "BRANCH":  // Branches are generated for `not`s which should be optimized out.
        throw "Unreachable (optimized out)"
      else:
        expect (not bytecode.name.starts-with "INVOKE")

  // Make sure that these are the only tests in that file.
  main-method := (extract-methods program ["main"])["main"]
  seen-invocations := {}
  main-method.do-bytecodes: |bytecode bci|
    if bytecode.name == "INVOKE_STATIC":
      target := target-of-invoke-static program main-method bci
      seen-invocations.add target.name
  expect-equals methods.size seen-invocations.size
  seen-invocations.do: expect (methods.contains it)
