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

  with-tmp-dir: | tmp-dir/string |
    src-path := "$tmp-dir/hello.toit"
    file.write-content --path=src-path """
      main: print "hello world"
      """
    output := toit-exe.backticks ["run", src-path]
    expect (output.contains "hello world")

    hello-executable := "$tmp-dir/hello"
    toit-exe.backticks ["compile", "-o", hello-executable, src-path]
    expect (file.is-file hello-executable)

    hello-snapshot := "$tmp-dir/hello.snapshot"
    toit-exe.backticks ["compile", "-o", hello-snapshot, "--snapshot", src-path]

    non-existing := "$tmp-dir/non-existing.toit"
    exception := catch: toit-exe.backticks ["run", non-existing]
    print "ERROR ABOVE IS EXPECTED"
    expect (exception.contains "exited with status 1")
    exception = catch: toit-exe.backticks ["compile", "-o", hello-executable, non-existing]
    print "ERROR ABOVE IS EXPECTED"
    expect (exception.contains "exited with status 1")
