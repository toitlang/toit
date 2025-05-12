// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import host.pipe
import io
import system

import .stdout-stderr-test-input as spawned

// Marked as compiler test so we get the toit.run path.
main args:
  toit-run := args[0]
  run-tests toit-run

TESTS ::= spawned.TESTS

run args --stdout/bool=false --stderr/bool=false -> string:
  process := pipe.fork
      --use-path
      --create-stdout=stdout
      --create-stderr=stderr
      args[0]
      args

  out-pipe := stdout ? process.stdout : process.stdin

  reader := out-pipe.in
  reader.buffer-all
  output := reader.read-string (reader.buffered-size)

  exit-value := process.wait
  exit-code := pipe.exit-code exit-value

  if exit-code != 0: throw "Program didn't exit with 0."
  return output

run-tests toit-run:
  this-file := system.program-path
  expect (this-file.ends-with "-compiler.toit")
  input-file := this-file.replace "-compiler.toit" "-input.toit"
  for i := 0; i < TESTS.size; i++:
    test/string := TESTS[i]
    stdout-output := run [toit-run, input-file, "RUN_TEST", "STDOUT", "$i"] --stdout
    stderr-output := run [toit-run, input-file, "RUN_TEST", "STDERR", "$i"] --stderr
    expect-equals stdout-output stderr-output

    expected := "$test\n".replace --all "\n" system.LINE-TERMINATOR
    expect-equals expected stdout-output
