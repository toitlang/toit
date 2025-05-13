// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import host.pipe
import expect show *

main args:
  toit-run := args[0]
  input := "tests/class_field_limit_input.toit"
  process := pipe.fork
      --use-path
      toit-run
      [
        toit-run,
        input
      ]
  exit-value := process.wait
  exit-code := pipe.exit-code exit-value

  expect-not-null exit-code
  expect-not-equals 0 exit-code
