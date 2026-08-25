// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import host.file

import .utils

main args:
  toit-exe := ToitExecutable args

  with-tmp-dir: | tmp-dir/string |
    source := "$tmp-dir/main.toit"
    snapshot := "$tmp-dir/main.snapshot"
    file.write-contents --path=source "main: print 42"

    normal := toit-exe.fork ["compile", "--snapshot", "-o", snapshot, source]
    expect-equals 0 normal.exit-code
    expect-not (normal.stderr.contains "Compiler timings:")

    verbose := toit-exe.fork [
      "compile",
      "--verbose",
      "--snapshot",
      "-o", snapshot,
      source,
    ]
    expect-equals 0 verbose.exit-code
    expect (verbose.stderr.contains "Compiler timings:")
    expect (verbose.stderr.contains "Parsing")
    expect (verbose.stderr.contains "Resolution")
    expect (verbose.stderr.contains "Type checks")
    expect (verbose.stderr.contains "Code generation")
    expect (verbose.stderr.contains "Snapshot generation")
    expect (verbose.stderr.contains "Total")
    expect-not (verbose.stderr.contains "(user ")
    expect-not (verbose.stderr.contains "Compiler statistics:")

    debug := toit-exe.fork [
      "compile",
      "--verbosity-level=debug",
      "--snapshot",
      "-o", snapshot,
      source,
    ]
    expect-equals 0 debug.exit-code
    expect (debug.stderr.contains "Compiler timings:")
    expect (debug.stderr.contains "Total")
    expect (debug.stderr.contains "(user ")
    expect (debug.stderr.contains "system ")
    expect (debug.stderr.contains "Compiler statistics:")
    expect (debug.stderr.contains "Source files")
    expect (debug.stderr.contains "Tokens")
    expect (debug.stderr.contains "Classes")
    expect (debug.stderr.contains "Bytecode bytes")
    expect (debug.stderr.contains "Program object bytes")
    expect (debug.stderr.contains "Dispatch table entries")
    expect (debug.stderr.contains "Snapshot bytes")
    expect (debug.stderr.contains "Bundle bytes")
