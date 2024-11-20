// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import host.pipe
import io
import system

// Marked as compiler test so we get the toit.run path.
main args:
  if args.size == 3 and args[0] == "RUN_TEST":
    is-stdout := args[1] == "STDOUT"
    test-case := int.parse args[2]
    run-spawned --is-stdout=is-stdout test-case
    return

  toit-run := args[0]
  run-tests toit-run

TESTS ::= [
  "",
  "foo",
  "foo\nbar",
]

run-spawned test-case/int --is-stdout/bool -> none:
  if is-stdout:
    print_ TESTS[test-case]
  else:
    print-on-stderr_ TESTS[test-case]

run args --stdout/bool=false --stderr/bool=false -> string:
  pipes := pipe.fork
      true    // use_path
      pipe.PIPE-INHERITED  // stdin
      stdout ? pipe.PIPE-CREATED : pipe.PIPE-INHERITED  // stdout
      stderr ? pipe.PIPE-CREATED : pipe.PIPE-INHERITED   // stderr
      args[0]
      args

  out-pipe := stdout ? pipes[1] : pipes[2]
  pid := pipes[3]

  reader := io.Reader.adapt out-pipe
  reader.buffer-all
  output := reader.read-string (reader.buffered-size)

  exit-value := pipe.wait-for pid
  exit-code := pipe.exit-code exit-value

  if exit-code != 0: throw "Program didn't exit with 0."
  return output

run-tests toit-run:
  this-file := system.program-path
  expect (this-file.ends-with ".toit")
  for i := 0; i < TESTS.size; i++:
    test/string := TESTS[i]
    stdout-output := run [toit-run, this-file, "RUN_TEST", "STDOUT", "$i"] --stdout
    stderr-output := run [toit-run, this-file, "RUN_TEST", "STDERR", "$i"] --stderr
    expect-equals stdout-output stderr-output

    expected := "$test\n".replace --all "\n" system.LINE-TERMINATOR
    expect-equals expected stdout-output
