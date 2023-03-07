// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import host.pipe
import .utils

EXPECTED_OUTPUT ::= "hello world"

main args:
  input := args[0]
  compiler := args[1]
  runner := args[2]

  with_tmp_directory: | tmp_dir|
    variants := compile_variants --compiler=compiler --tmp_dir=tmp_dir input

    variants.do:
      expect_equals EXPECTED_OUTPUT (pipe.backticks runner it).trim
