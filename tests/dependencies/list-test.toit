// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import host.pipe
import system
// Imported, but not used.
// It should still be in the dependencies list.
import .list-other

main args:
  toitc := args[0]
  my-path := system.program-path

  out := pipe.backticks [toitc, "--dependencies", my-path]
  out = out.replace --all "\r" ""
  lines := out.split "\n"
  expect (lines.contains my-path)
  expect (lines.any: it.contains "list-other.toit")
