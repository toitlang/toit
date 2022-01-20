// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  b0 := MessageBox
  expect_equals
    87
    b0.send 87

class MessageBox:
  send x:
    do:
      do: msg == null
      msg = x
    return msg
  do [block]:
    block.call
  msg := null
