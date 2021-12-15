// Copyright (C) 2019 Toitware ApS. All rights reserved.

import expect show *

main:
  x := {
    "f" : :: it,
    "g" : :: it + 1,
  }
  expect_equals 499 (x["f"].call 499)
  expect_equals 42  (x["g"].call 41)

  x = {
    if true: "f"
    else: "g":
    :: it,
    if false: "f"
    else: "g":
    :: it + 1,
  }
  expect_equals 499 (x["f"].call 499)
  expect_equals 42  (x["g"].call 41)

  y := [
    :: it,
    :: it + 1,
  ]
  expect_equals 499 (y[0].call 499)
  expect_equals 42  (y[1].call 41)
