// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  exception := catch: recurse
  expect_null exception  // The exception is turned into null by [execute].

recurse:
  value := execute --print_trace=true (:recurse): return null
  expect_null value
  return null  // TODO(florian,kasper): check missing return.

execute --print_trace=false [block] [fail_block]:
  catch
    --trace=print_trace
    --unwind=: | exception trace |
      return fail_block.call exception trace
    :
      return block.call
  unreachable
