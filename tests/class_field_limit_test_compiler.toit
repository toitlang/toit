// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import host.pipe
import expect show *

main args:
  toit_run := args[0]
  input := "tests/class_field_limit_input.toit"
  pipes := pipe.fork
      true                // use_path
      pipe.PIPE_INHERITED // stdin
      pipe.PIPE_INHERITED // stdout
      pipe.PIPE_INHERITED // stderr
      toit_run
      [
        toit_run,
        input
      ]
  to   := pipes[0]
  from := pipes[1]
  pid  := pipes[3]
  exit_value := pipe.wait_for pid
  exit_code := pipe.exit_code exit_value

  expect_not_null exit_code
  expect_equals 255 exit_code
