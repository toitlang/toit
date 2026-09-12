// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import host.file
import host.pipe

import .utils

main args:
  toit-exe := ToitExecutable args

  with-tmp-dir: | tmp-dir/string |
    src-path := "$tmp-dir/hello.toit"
    file.write-contents --path=src-path """
      main args:
        args.do: print it
      """

    // Test: `toit -- hello.toit arg1 arg2` should run the file with args.
    output := toit-exe.backticks ["--", src-path, "arg1", "arg2"]
    expect (output.contains "arg1")
    expect (output.contains "arg2")

    // Test: `toit -- hello.toit` with no extra args.
    output = toit-exe.backticks ["--", src-path]
    // Should succeed without error.

    // Test: bare `toit --` with no source file.
    fork-result := toit-exe.fork ["--"]
    expect-not-equals 0 fork-result.exit-code
    combined := fork-result.stdout + fork-result.stderr
    expect (combined.contains "Missing source file after")

    // Test: invalid first argument that is not a command or source file.
    fork-result = toit-exe.fork ["not-a-command"]
    expect-not-equals 0 fork-result.exit-code
    combined = fork-result.stdout + fork-result.stderr
    expect (combined.contains "Unknown command or invalid source file")

    // Short files without a Toit extension aren't source files.
    short-path := "$tmp-dir/short"
    ["", "#", "!", "x"].do: | contents/string |
      file.write-contents --path=short-path contents
      [[], ["--"]].do: | prefix/List |
        result := toit-exe.fork (prefix + [short-path])
        expect-equals 1 result.exit-code
        message := result.stdout + result.stderr
        expect (message.contains "Unknown command or invalid source file")

    // Files without a Toit extension can still be shebang scripts or snapshots.
    script-path := "$tmp-dir/script"
    file.write-contents --path=script-path
        "#!/usr/bin/env toit\n" + (file.read-contents src-path).to-string
    snapshot-path := "$tmp-dir/snapshot"
    toit-exe.backticks ["compile", "--snapshot", "-o", snapshot-path, src-path]
    [src-path, script-path, snapshot-path].do: | path/string |
      [[], ["--"]].do: | prefix/List |
        expect-equals "hello\n" (toit-exe.backticks (prefix + [path, "hello"]))
