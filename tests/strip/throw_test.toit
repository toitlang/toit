// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import host.pipe
import .utils

EXPECTED_EXCEPTION_OUTPUT ::= "some exception"

main args:
  input := args[0]
  compiler := args[1]
  runner := args[2]

  with_tmp_directory: | tmp_dir|
    variants := compile_variants --compiler=compiler --tmp_dir=tmp_dir input

    non_stripped_snapshot := variants[0]
    output := backticks_failing [runner, non_stripped_snapshot]
    expect (output.contains EXPECTED_EXCEPTION_OUTPUT)
    expect (output.contains ".toit")  // At least on stack trace frame.

    variants[1..].do:
      output = backticks_failing [runner, it]
      expect (output.contains EXPECTED_EXCEPTION_OUTPUT)
      expect_not (output.contains ".toit")
