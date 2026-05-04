// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import host.file

import .utils

main args:
  toit-exe := ToitExecutable args

  with-tmp-dir: | tmp-dir/string |
    src1 := "$tmp-dir/hello.toit"
    src2 := "$tmp-dir/world.toit"
    file.write-contents --path=src1 """
      main: print "hello"
      """
    file.write-contents --path=src2 """
      main: print "world"
      """

    // Single file analyze.
    toit-exe.backticks ["analyze", src1]

    // Multi file analyze.
    toit-exe.backticks ["analyze", src1, src2]

    // Non-existing file.
    non-existing := "$tmp-dir/non-existing.toit"
    exception := catch: toit-exe.backticks ["analyze", non-existing]
    expect (exception.contains "exited with status 1")

    // Erroneous file.
    bad := "$tmp-dir/bad.toit"
    file.write-contents --path=bad "main: undefined-variable"
    fork-result := toit-exe.fork ["analyze", bad]
    expect-not-equals 0 fork-result.exit-code
