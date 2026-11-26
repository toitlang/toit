// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// A program whose spawned process dies with an uncaught exception must end
// with a non-zero exit code (spawn-uncaught-exit-code-input.toit). The
// system process exits with the error after killing the other processes.
// While the scheduler deletes the system process, the termination messages
// of the killed processes (exit value 0) must not decide the exit code.
// The race needs many runs to show, so the input is compiled once and its
// snapshot is run repeatedly.

import expect show *
import host.directory
import host.os
import host.pipe

RUNS ::= 30

// Marked as compiler test so we get the toit.run path.
main args:
  toit-run := args[0]
  input := "tests/spawn-uncaught-exit-code-input.toit"
  tmp := os.env.get "TMPDIR" or "/tmp"
  dir := directory.mkdtemp "$tmp/spawn-uncaught-exit-code-"
  try:
    snapshot := "$dir/input.snapshot"
    expect-equals 0 (pipe.run-program [toit-run, "-w", snapshot, input])
    RUNS.repeat: | run/int |
      process := pipe.fork
          --use-path
          --create-stderr
          toit-run
          [toit-run, snapshot]
      stderr := process.stderr.in.read-all.to-string
      exit-value := process.wait
      expect-null (pipe.exit-signal exit-value)
      exit-code := pipe.exit-code exit-value
      expect (exit-code != 0) --message="run $run ended with exit code 0"
      expect (stderr.contains "UNCAUGHT")
  finally:
    directory.rmdir --recursive dir
