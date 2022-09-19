// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

fun499: return 499
bar x: return x + 1

main:
  if var := fun499:
    expect_equals 499 var

  map := {
    "a": [1, 2],
    "b": [3, 4],
  }

  ["a", "b"].do: | entry |
    if value := map.get entry:
      if entry == "a":
        expect_equals [1, 2] value
      else:
        expect_equals [3, 4] value
      // When a bug in the condition-variable code was found, this 'do' would
      // fail with:
      //   Class 'int' does not have any method 'do'.
      value.do: bar it
