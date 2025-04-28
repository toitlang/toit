// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .utils
import ...tools.snapshot show *
import expect show *
import host.file
import host.directory

main args:
  sizes-test-path := directory.realpath "$directory.cwd/../sizes-test.toit"

  snap := run args --entry-path=sizes-test-path
  program := snap.decode
  methods := extract-methods program ["main"]

  main-method := methods.values.first
  expect main-method != null
  INVOKE-SIZE-bytecodes := 0
  main-method.do-bytecodes: |bytecode bci|
    if bytecode.name == "INVOKE_SIZE":
      INVOKE-SIZE-bytecodes++

  // We only check that there are a few INVOKE_SIZE bytecodes.
  // We don't want to change this test every time we add a new line to the test.
  expect (INVOKE-SIZE-bytecodes > 5)
