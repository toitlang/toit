// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import host.pipe
import expect show *

main args:
  toit-run := args[0]
  input := "tests/cow-read-only-input.toit"
  process := pipe.fork
      --use-path
      --create-stderr
      toit-run
      [
        toit-run,
        input
      ]
  stderr := process.stderr.in.read-all.to-string
  exit-value := process.wait

  // Stores into the read-only program heap are rejected with an exception
  // (they used to be a segmentation fault).
  expect-null (pipe.exit-signal exit-value)
  expect-not-equals 0 (pipe.exit-code exit-value)
  expect (stderr.contains "PERMISSION_DENIED")
