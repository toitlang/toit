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
      toit-run
      [
        toit-run,
        input
      ]
  exit-value := process.wait

  expect-not-null (pipe.exit-signal exit-value)
