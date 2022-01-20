// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

run [block]:
  block.call

ret_false: return false

main:
  after_call := false
  while true:
    local := 122
    block := : 499 + local
    // In order to compile the jump to the loop-exit,
    //   we need to pop all stack-slots that were
    //   allocated inside the loop.
    // When resuming the compilation of the loop body, we must
    //   correctly restore the stack with the correct types.
    if ret_false: break
    block.call  // The block call will check whether the target is a block.
    after_call = true
    break
  expect after_call
