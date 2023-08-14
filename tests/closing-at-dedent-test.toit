// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  executed := false
  fun := (:
    executed = true
  )  // Closing parenthesis at dedent-level.
  fun.call
  expect executed

  map := {
    "foo": "bar"
  }  // Closing brace at dedent-level.

  list := [
    1
  ]  // Closing bracket at dedent-level.
