// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

expect-error name [code]:
  expect-equals
    name
    catch code

expect-out-of-bounds [code]:
  expect-error "OUT_OF_BOUNDS" code

expect-wrong-object-type [code]:
  exception-name := catch code
  expect
      exception-name == "WRONG_OBJECT_TYPE" or exception-name == "AS_CHECK_FAILED"

test-to-16:
  expect-equals
    #[]
    "".to-utf-16

  expect-equals
    #['H', 0]
    "H".to-utf-16

  expect-equals
    #['æ', 0]
    "æ".to-utf-16

  expect-equals
    #[0xac, 0x20, '0', 0, ',', 0, '9', 0, '8', 0]
    "€0,98".to-utf-16

  expect-equals
    #['(', 0, 0x3d, 0xd8, 0x39, 0xde, ')', 0]  // Surrogate pair for U+1F639.
    "(😹)".to-utf-16

test-from-16:
  expect-equals
    ""
    string.from-utf-16 #[]

  expect-equals
    "H"
    string.from-utf-16 #['H', 0]

  expect-equals
    "æ"
    string.from-utf-16 #['æ', 0]

  expect-equals
    "€0,98"
    string.from-utf-16 #[0xac, 0x20, '0', 0, ',', 0, '9', 0, '8', 0]

  expect-equals
    "(😹)"
    string.from-utf-16 #['(', 0, 0x3d, 0xd8, 0x39, 0xde, ')', 0]  // Surrogate pair for U+1F639.

  // The surrogate pair starts at an odd byte offset in the backing array.
  padded := #[0xff, 0x3d, 0xd8, 0x39, 0xde, 0xff]
  expect-equals "😹" (string.from-utf-16 padded[1..5])
  expect-equals "\u{fffd}" (string.from-utf-16 padded[1..3])
  expect-error "INVALID_ARGUMENT": string.from-utf-16 padded[1..4]

  // Unpaired surrogate is replaced with a error character, 0xfffd.
  expect-equals
    "<\u{fffd}>"
    string.from-utf-16 #['<', 0, 0xde, 0xde, '>', 0]

main:
  test-to-16
  test-from-16
