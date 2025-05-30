// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import host.pipe
import host.directory

with-tmp-directory [block]:
  tmp-dir := directory.mkdtemp "/tmp/toit-strip-test-"
  try:
    block.call tmp-dir
  finally:
    directory.rmdir --recursive tmp-dir

backticks-failing args/List -> string:
  process := pipe.fork
      --use-path
      --create-stdin
      --create-stdout
      --create-stderr
      args[0]
      args
  process.stdin.close

  // We are merging stdout and stderr into one stream.
  stdout-output/ByteArray? := null
  stderr-output/ByteArray? := null
  exit-value/int := 0
  Task.group [
    :: stdout-output = process.stdout.in.read-all,
    :: stderr-output = process.stderr.in.read-all,
    :: exit-value = process.wait
  ]
  // The test is supposed to fail.
  expect-not-equals 0 exit-value

  return (stdout-output + stderr-output).to-string

/**
Compiles the $input and returns three variants.
The first entry is a non-stripped snapshot. The others are stripped.
*/
compile-variants --compiler/string input/string --tmp-dir/string -> List:
  result := []

  non-stripped-snapshot := "$tmp-dir/non_stripped.snapshot"
  output := pipe.backticks compiler "-w" non-stripped-snapshot input
  expect-equals "" output.trim
  result.add non-stripped-snapshot

  stripped-snapshot := "$tmp-dir/stripped.snapshot"
  output = pipe.backticks compiler "--strip" "-w" stripped-snapshot input
  expect-equals "" output.trim
  result.add stripped-snapshot

  // Now strip the unstripped snapshot and run that one.
  stripped-snapshot2 := "$tmp-dir/stripped2.snapshot"
  output = pipe.backticks compiler "--strip" "-w" stripped-snapshot2 non-stripped-snapshot
  expect-equals "" output.trim
  result.add stripped-snapshot2

  return result
