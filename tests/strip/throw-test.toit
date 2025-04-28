// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import host.pipe
import .utils

EXPECTED-EXCEPTION-OUTPUT ::= "some exception"

main args:
  input := args[0]
  compiler := args[1]
  runner := args[2]

  with-tmp-directory: | tmp-dir |
    variants := compile-variants --compiler=compiler --tmp-dir=tmp-dir input

    non-stripped-snapshot := variants[0]
    output := backticks-failing [runner, non-stripped-snapshot]
    print "Variant 0:"
    print output
    expect (output.contains EXPECTED-EXCEPTION-OUTPUT)
    expect (output.contains ".toit")  // At least on stack trace frame.

    variants[1..].do:
      output = backticks-failing [runner, it]
      print "Variant $it:"
      print output
      expect (output.contains EXPECTED-EXCEPTION-OUTPUT)
      expect-not (output.contains ".toit")
