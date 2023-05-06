// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

ON_DEVICE ::= platform == PLATFORM_FREERTOS

main:
  10.repeat:
    if ON_DEVICE:
      allocate_too_much
    else:
      20.repeat:
        spawn:: allocate_too_much

allocate_too_much:
  // Always allow at least one page, so the test
  // can succeed even if we end up having promoted
  // a little bit of memory after the long string
  // allocation has been cleaned up.
  if not ON_DEVICE: set_max_heap_size_ (1 << 15)
  error ::= catch:
    10.repeat:
      x := "foo"
      25.repeat: x += x
  expect_equals "ALLOCATION_FAILED" error
