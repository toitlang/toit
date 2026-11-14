// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

// The object encoder (encode-error_ and encode_) must not read a proxy byte
// array (an external byte array whose address is a C++ object: a timer, a
// resource group) as bytes. It used to, and builds with assertions stopped
// the VM: "assertion failure, external_tag() == RawByteTag || ...".

main:
  timer := timer-create_ timer-resource-group_
  // As the message of an error, and inside lists.
  [timer, [timer], [[1, timer]], timer-resource-group_].do: | message |
    expect (encode-error_ "X" message) is ByteArray
    expect (encode_ message) is ByteArray
  // Raw byte arrays are still encoded.
  expect (encode-error_ "X" #[1, 2, 3]) is ByteArray
  expect (encode_ #[1, 2, 3]) is ByteArray
  timer-delete_ timer-resource-group_ timer
