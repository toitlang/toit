// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .utils
import ...tools.snapshot show *
import expect show *

AS-NAMES := [
  "AS_CLASS",
  "AS_CLASS_WIDE",
  "AS_INTERFACE",
  "AS_INTERFACE_WIDE",
  "AS_LOCAL"
]

// Test that the byte-array literals don't introduce as-checks.
main args:
  snap := run args --entry-path="///untitled" {
    "///untitled": """

    main args:
      x := #[]
      x = #[1]
      x = #[1, 2, 3, 4, 5, 6]
      // Add one 'as' check to make sure we don't miss them entirely.
      y := (args[0] == "foo" ? "str" : 499)
      print (y as string)
    """
  }

  program := snap.decode
  methods := extract-methods program ["main"]
  main-method /ToitMethod:= methods["main"]
  as-check-count := 0
  main-method.do-bytecodes:
    if AS-NAMES.contains it.name: as-check-count++
  expect-equals 1 as-check-count
