// Copyright (C) 2018 Toitware ApS. All rights reserved.

import expect show *

main:
  // ==
  expect 1   ==   1 --message="1 == 1"
  expect 1   == 1.0 --message="1 == 1.0"
  expect 1.0 ==   1 --message="1.0 == 1"
  expect 1.0 == 1.0 --message="1.0 == 1.0"

  // !=
  expect 1   != 2   --message="1 != 1"
  expect 1   != 2.0 --message="1 != 2.0"
  expect 1.0 != 2   --message="1.0 != 2"
  expect 1.0 != 2.0 --message="1.0 != 2.0"

  // +
  expect (1 + 1)     == 2 --message="(1+1) == 2"
  expect (1 + 1.0)   == 2 --message="(1+0.0) == 1"
  expect (1.0 + 1)   == 2 --message="(1.0+1) == 2"
  expect (1.0 + 1.0) == 2 --message="(1.0+1) == 2"

  // -
  expect (2 - 1)     == 1 --message="(2-1) == 1"
  expect (2 - 1.0)   == 1 --message="(2-1.0) == 1"
  expect (2.0 - 1)   == 1 --message="(2.0-1) == 1"
  expect (2.0 - 1.0) == 1 --message="(2.0-1.0) == 1"

  // *
  expect (2 * 2)     == 4 --message="(2*2) == 4"
  expect (2 * 2.0)   == 4 --message="(2*2.0) == 4"
  expect (2.0 * 2)   == 4 --message="(2.0*2) == 4"
  expect (2.0 * 2.0) == 4 --message="(2.0*2.0) == 4"

  // /
  expect (4 / 2)     == 2 --message="(4/2) == 2"
  expect (4 / 2.0)   == 2 --message="(4.0/2.0) == 2"
  expect (4.0 / 2)   == 2 --message="(4.0/2) == 2"
  expect (4.0 / 2.0) == 2 --message="(4.0/2.0) == 2"

  // & binds tighter than ==
  expect 1 & 1 == 1 & 1
