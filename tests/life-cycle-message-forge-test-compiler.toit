// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Only the VM may send the TERMINATED and SPAWNED system messages
// (life-cycle-message-forge-input.toit). The system process trusts them: a
// forged TERMINATED notice with payload 42 made it stop the program's
// container, and the program exited with code 42 while it was still running.

import host.pipe
import expect show *

// Marked as compiler test so we get the toit.run path.
main args:
  toit-run := args[0]
  input := "tests/life-cycle-message-forge-input.toit"
  process := pipe.fork
      --use-path
      --create-stdout
      toit-run
      [
        toit-run,
        input
      ]
  stdout := process.stdout.in.read-all.to-string
  exit-value := process.wait

  expect-null (pipe.exit-signal exit-value)
  expect-equals 0 (pipe.exit-code exit-value)
  lines := (stdout.trim.split "\n").map: it.trim
  expect-equals 5 lines.size
  4.repeat:
    expect (lines[it].ends-with ": PERMISSION_DENIED")
  expect-equals "done" lines[4]
