// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import host.pipe
import .utils

main args:
  i := 0
  snap := args[i++]
  toit-run := args[i++]

  // Get the indexes from the program.
  out /string := pipe.backticks [toit-run, snap]
  lines := out.split LINE-TERMINATOR
  lines.do:
    if it == "": continue.do
    parts := it.split " - "
    index := int.parse parts[0]
    size := int.parse parts[1]
    first-line := parts[2]

    test-out := run-toitp args ["--literal", "$index"]
    first-out-line := (test-out.split "\n")[0]
