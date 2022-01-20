// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

check expected object:
  expect_equals expected object.stringify

main:
  check "234"    234
  check "true"   true
  check "false"  false
  check "Fisk"   "Fisk"
  check "[1, 2]" [1, 2]
  check "[null, true, false, 1, 2]" [null, true, false, 1, 2]
  check "[[], [[]]]" [[], [[]]]
  check
    "#[0x00, 0x00]"
    ByteArray 2
  check "{}"   {}
  check "{12}" {12, 12}
  check "{:}"  {:}
  check "{1: 2, 3: [4, 5]}" {1: 2, 3: [4, 5]}
  check_big_map

check_big_map:
  big_map := {:}
  1000.repeat: big_map[it] = it
  expect (big_map.stringify.ends_with "...")
