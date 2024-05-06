// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import system
import system show platform tune-memory-use

ON-DEVICE ::= platform == system.PLATFORM-FREERTOS

main:
  tune-memory-use 0
  10.repeat:
    if ON-DEVICE:
      allocate-too-much
    else:
      20.repeat:
        spawn:: allocate-too-much

allocate-too-much:
  // Always allow at least one page, so the test
  // can succeed even if we end up having promoted
  // a little bit of memory after the long string
  // allocation has been cleaned up.
  if not ON-DEVICE: set-max-heap-size_ (1 << 15)
  error ::= catch:
    10.repeat:
      x := "foo"
      25.repeat: x += x
  expect-equals "ALLOCATION_FAILED" error
