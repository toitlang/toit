// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import host.pipe
import expect show *

main args:
  toit_run := args[0]
  input := "tests/cow_read_only_input.toit"
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

  expect_not_null (pipe.exit_signal exit_value)
