// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import host.pipe
import .utils

EXPECTED-OUTPUT ::= "hello world"

main args:
  input := args[0]
  compiler := args[1]
  runner := args[2]

  with-tmp-directory: | tmp-dir|
    variants := compile-variants --compiler=compiler --tmp-dir=tmp-dir input

    variants.do:
      expect-equals EXPECTED-OUTPUT (pipe.backticks runner it).trim
