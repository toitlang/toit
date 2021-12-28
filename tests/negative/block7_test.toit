// Copyright (C) 2018 Toitware ApS. All rights reserved.

import expect show *

class A:
  operator [] [b]:
    return b.call

  stored := 0
  operator []= [b] [b2]:
    stored = b.call + b2.call

main:
  expect_equals 499 A[:499]
  a := A
  a[:400] = :99
  expect_equals 499 a.stored
