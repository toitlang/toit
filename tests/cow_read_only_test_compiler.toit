// Copyright (C) 2020 Toitware ApS. All rights reserved.

import ..tools.pipe as pipe
import expect show *

main args:
  toitc := args[0]
  input := "tests/cow_read_only_input.toit"
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

  expect_not_null (pipe.exit_signal exit_value)
