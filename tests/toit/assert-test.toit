// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import host.directory
import host.file
import host.pipe
import system

import .utils

main args:
  toit-exe := ToitExecutable args

  print "ASSERTION ERRORS ARE EXPECTED IN THIS TEST"

  with-tmp-dir: | tmp-dir/string |
    src-path := "$tmp-dir/assert.toit"
    file.write-content --path=src-path """
      main args:
        // The assert will always fail.
        assert: args.size > 100
      """
    exit-code := toit-exe.run ["run", src-path]
    expect-equals 1 exit-code

    exit-code = toit-exe.run ["run", "-O2", src-path]
    expect-equals 0 exit-code

    exit-code = toit-exe.run ["run", "--no-enable-asserts", "-O1", src-path]
    expect-equals 0 exit-code

    exit-code = toit-exe.run ["run", "--enable-asserts", "-O2", src-path]
    expect-equals 1 exit-code

    assert-executable := "$tmp-dir/assert"
    toit-exe.backticks ["compile", "-o", assert-executable, src-path]
    expect (file.is-file assert-executable)
    exit-code = pipe.run-program assert-executable
    expect-equals 1 exit-code

    toit-exe.backticks ["compile", "-O2", "-o", assert-executable, src-path]
    exit-code = pipe.run-program assert-executable
    expect-equals 0 exit-code

    toit-exe.backticks ["compile", "--no-enable-asserts", "-o", assert-executable, src-path]
    exit-code = pipe.run-program assert-executable
    expect-equals 0 exit-code

    toit-exe.backticks ["compile", "--enable-asserts", "-O2", "-o", assert-executable, src-path]
    exit-code = pipe.run-program assert-executable
    expect-equals 1 exit-code
