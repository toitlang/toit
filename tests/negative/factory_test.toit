// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  expect_equals 3
    Point 7 4

class Point:
  constructor x y:
    return x - y

  constructor x:
