// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

run [block]: return block.call "str"
run fun/Lambda: return fun.call "str"

main:
  expect_equals "tr"
      run: |x/string|
        x.copy 1

  expect_equals "tr"
      run:: |x/string|
        x.copy 1

  expect_equals "tr"
      run:: |it/string|
        it.copy 1
