// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import host.pipe
import host.directory

with_tmp_directory [block]:
  tmp_dir := directory.mkdtemp "/tmp/toit-strip-test-"
  try:
    block.call tmp_dir
  finally:
    directory.rmdir --recursive tmp_dir

backticks_failing args/List -> string:
  pipes := pipe.fork
      true                // use_path
      pipe.PIPE_CREATED   // stdin
      pipe.PIPE_CREATED   // stdout
      pipe.PIPE_CREATED   // stderr
      args[0]
      args
  pipes[0].close
  stdout := pipes[1]
  stderr := pipes[2]
  pid  := pipes[3]

  // We are merging stdout and stderr into one stream.
  stdout_output := #[]
  task::
    while chunk := stdout.read:
      stdout_output += chunk

  stderr_output := #[]
  task::
    while chunk := stderr.read:
      stderr_output += chunk

  // The test is supposed to fail.
  expect_not_equals 0 (pipe.wait_for pid)

  return (stdout_output + stderr_output).to_string

/**
Compiles the $input and returns three variants.
The first entry is a non-stripped snapshot. The others are stripped.
*/
compile_variants --compiler/string input/string --tmp_dir/string -> List:
  result := []

  non_stripped_snapshot := "$tmp_dir/non_stripped.snapshot"
  output := pipe.backticks compiler "-w" non_stripped_snapshot input
  expect_equals "" output.trim
  result.add non_stripped_snapshot

  stripped_snapshot := "$tmp_dir/stripped.snapshot"
  output = pipe.backticks compiler "--strip" "-w" stripped_snapshot input
  expect_equals "" output.trim
  result.add stripped_snapshot

  // Now strip the unstripped snapshot and run that one.
  stripped_snapshot2 := "$tmp_dir/stripped2.snapshot"
  output = pipe.backticks compiler "--strip" "-w" stripped_snapshot2 non_stripped_snapshot
  expect_equals "" output.trim
  result.add stripped_snapshot2

  return result
