// Copyright (C) 2018 Toitware ApS. All rights reserved.

import expect show *

main:
  expect_equals 3
    Point 7 4

class Point:
  constructor x y:
    return x - y

  constructor x:
