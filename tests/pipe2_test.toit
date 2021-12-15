// Copyright (C) 2019 Toitware ApS. All rights reserved.

import expect show *

import ..tools.directory show *
import ..tools.file as file
import ..tools.pipe as pipe

test_exit_value command args expected_exit_value sleep_time/int:
  complete_args := [command] + args
  pipes := pipe.fork
    true  // use_path
    pipe.PIPE_CREATED  // stdin
    pipe.PIPE_CREATED  // stdiout
    pipe.PIPE_CREATED  // stderr
    command
    complete_args

  pid := pipes[3]

  task::
    if sleep_time != 0: sleep --ms=sleep_time
    pipes[0].close

  exit_value := pipe.wait_for pid

  expect_equals expected_exit_value (pipe.exit_code exit_value)
  expect_equals null (pipe.exit_signal exit_value)


test_exit_signal sleep_time/int:
  // Start long running process.
  pipes := pipe.fork
    true  // use_path
    pipe.PIPE_CREATED  // stdin
    pipe.PIPE_CREATED  // stdiout
    pipe.PIPE_CREATED  // stderr
    "/bin/cat"
    ["/bin/cat"]

  pid := pipes[3]

  SIGKILL := 9
  task::
    if sleep_time != 0: sleep --ms=sleep_time
    pipe.kill_ pid SIGKILL

  exit_value := pipe.wait_for pid

  expect_equals null (pipe.exit_code exit_value)
  expect_equals SIGKILL (pipe.exit_signal exit_value)

main:
  // This test does not work on ESP32 since you can't launch subprocesses.
  if platform == "FreeRTOS": return

  test_exit_value "cat" [] 0 0
  test_exit_value "cat" [] 0 20

  test_exit_value "grep" ["foo"] 1 0
  test_exit_value "grep" ["foo"] 1 20

  test_exit_signal 0
  test_exit_signal 20
