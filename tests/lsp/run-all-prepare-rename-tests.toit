// Copyright (C) 2026 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Runs all prepare-rename LSP tests and reports a summary.

Usage:
  toit run -- tests/lsp/run-all-prepare-rename-tests.toit <toit-exe> <server.toit> <mock-compiler>

Arguments must be absolute paths:
  - toit-exe: The toit runner executable.
  - server.toit: The LSP server script.
  - mock-compiler: The mock compiler executable.
*/

import host.directory
import host.file
import host.pipe
import system

RUNNER-PATH ::= "tests/lsp/prepare-rename-test-runner.toit"
TEST-DIR    ::= "tests/lsp"
TEST-SUFFIX ::= "-prepare-rename-test.toit"

main args:
  if args.size < 3:
    print "Usage: toit run -- $RUNNER-PATH <toit-exe> <server.toit> <mock-compiler>"
    system.exit 1

  toit-exe      := args[0]
  server-path   := args[1]
  mock-compiler := args[2]

  test-files := find-test-files TEST-DIR TEST-SUFFIX
  if test-files.is-empty:
    print "No test files found in $TEST-DIR matching *$TEST-SUFFIX"
    system.exit 1

  passed  := 0
  failed  := 0
  errored := 0

  test-files.do: |test-file/string|
    name := test-file
    // Strip directory prefix and suffix for display.
    if name.starts-with "$TEST-DIR/":
      name = name[(TEST-DIR.size + 1)..]
    if name.ends-with TEST-SUFFIX:
      name = name[..name.size - TEST-SUFFIX.size]

    abs-test-path := "$directory.cwd/$test-file"
    exit-code := run-test
        --toit-exe=toit-exe
        --runner=RUNNER-PATH
        --test-path=abs-test-path
        --server=server-path
        --mock=mock-compiler
    if exit-code == 0:
      print "PASS:  $name"
      passed++
    else:
      print "FAIL:  $name (exit=$exit-code)"
      failed++

  print ""
  print "=============================="
  total := passed + failed + errored
  print "RESULTS: $passed/$total passed, $failed failed, $errored errored"
  print "=============================="
  if failed + errored > 0:
    system.exit 1

/**
Discovers test files in the given directory matching the suffix.
*/
find-test-files dir/string suffix/string -> List:
  result := []
  stream := directory.DirectoryStream dir
  try:
    while entry := stream.next:
      if entry.ends-with suffix:
        result.add "$dir/$entry"
  finally:
    stream.close
  result.sort
  return result

/**
Runs a single prepare-rename test and returns the exit code.
*/
run-test --toit-exe/string --runner/string --test-path/string --server/string --mock/string -> int:
  command := [
    toit-exe,
    "run",
    "--",
    runner,
    test-path,
    toit-exe,
    server,
    mock,
  ]
  return pipe.run-program command
