// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

check expected object:
  expect-equals expected object.stringify

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
  check-big-map

check-big-map:
  big-map := {:}
  1000.repeat: big-map[it] = it
  expect (big-map.stringify.ends-with "...")
