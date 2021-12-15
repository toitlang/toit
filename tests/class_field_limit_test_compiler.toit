// Copyright (C) 2020 Toitware ApS. All rights reserved.

import host.pipe
import expect show *

main args:
  toitc := args[0]
  input := "tests/class_field_limit_input.toit"
  pipes := pipe.fork
      true                // use_path
      pipe.PIPE_INHERITED // stdin
      pipe.PIPE_INHERITED // stdout
      pipe.PIPE_INHERITED // stderr
      toitc
      [
        toitc,
        input
      ]
  to   := pipes[0]
  from := pipes[1]
  pid  := pipes[3]
  exit_value := pipe.wait_for pid
  exit_code := pipe.exit_code exit_value

  expect_not_null exit_code
  expect_equals 255 exit_code
