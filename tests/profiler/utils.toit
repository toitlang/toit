// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import io
import system

import host.pipe

/**
Runs the given test with $args containing `toit.run` as first argument, and
  the input as second.

Returns the lines of the output.
Throws if the program didn't terminate with exit code 0.
*/
run args -> List:
  toitrun := args[0]
  profiled-path := args[1]

  pipes := pipe.fork
      true    // use_path
      pipe.PIPE-INHERITED  // stdin
      pipe.PIPE-INHERITED  // stdout
      pipe.PIPE-CREATED    // stderr
      toitrun
      [ toitrun, profiled-path ]

  stderr := pipes[2]
  pid := pipes[3]

  reader := io.Reader.adapt stderr
  reader.buffer-all
  output := reader.read-string (reader.buffered-size)

  exit-value := pipe.wait-for pid
  exit-code := pipe.exit-code exit-value

  if exit-code != 0: throw "Program didn't exit with 0."
  lines := output.split system.LINE-TERMINATOR
  return lines
