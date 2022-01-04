// Copyright (C) 2021 Toitware ApS. All rights reserved.

import expect show *
import host.pipe
import .utils

main args:
  i := 0
  snap := args[i++]
  toit_run := args[i++]

  // Get the indexes from the program.
  out /string := pipe.backticks [toit_run, snap]
  lines := out.split "\n"
  lines.do:
    if it == "": continue.do
    parts := it.split " - "
    index := int.parse parts[0]
    size := int.parse parts[1]
    first_line := parts[2]

    test_out := run_toitp args ["--literal", "$index"]
    first_out_line := (test_out.split "\n")[0]
