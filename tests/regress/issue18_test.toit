// Copyright (C) 2022 Toitware ApS. All rights reserved.

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
