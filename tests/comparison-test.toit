// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  // <=
  expect 1 <= 1   --message="1 <= 1"
  expect 1 <= 2   --message="1 <= 2"
  expect 1 <= 1.0 --message="1 <= 1.0"
  expect 1 <= 2.0 --message="1 <= 2.0"
  expect 1.0 <= 1 --message="1.0 <= 1"
  expect 1.0 <= 2 --message="1.0 <= 2"

  // <
  expect 1 < 2   --message="1 <= 2"
  expect 1 < 2.0 --message="1 <= 2.0"
  expect 1.0 < 2 --message="1.0 <= 2"

  // >=
  expect 1 >= 1   --message="1 >= 1"
  expect 2 >= 1   --message="2 >= 1"
  expect 1 >= 1.0 --message="1 >= 1.0"
  expect 2 >= 1.0 --message="2 >= 1.0"
  expect 1.0 >= 1 --message="1.0 >= 1"
  expect 2.0 >= 1 --message="2.0 >= 1"

  // >
  expect 2 > 1    --message="2 >= 1"
  expect 2 >= 1.0 --message="2 >= 1.0"
  expect 2.0 >= 1 --message="2.0 >= 1"

  // !=
  expect 2 != 1   --message="2 != 1"
  expect 2 != 1.0 --message="2 != 1.0"
  expect 2.0 != 1 --message="2.0 != 1"

  expect 2 < 3        --message="less than - #1"
  expect 0 <= 0       --message="less than equals - #1"
  expect (-1) <= (-1) --message="less than equals - #2"
  expect -1 <= -1     --message="less than equals - #3"
