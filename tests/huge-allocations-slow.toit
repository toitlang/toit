// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  if platform != "FreeRTOS":
    test-huge-allocations

test-huge-allocations:
  [0x2000_0000, 0x4000_0000, 0x8000_0000].do: | base-size |
    4.repeat:
      size := base-size - (it + 1) * 4
      test-huge-byte-array size
      test-huge-string size

test-huge-byte-array size/int -> none:
  exception := catch:
    byte-array := ByteArray size
    // Allocation succeeded.  Let's check if it actually has the size it should.
    byte-array[size - 1] = 0x34
    byte-array[0] = 0x34
  if exception:
    expect-equals "OUT_OF_RANGE" exception

test-huge-string size/int -> none:
  exception := catch:
    str := "*" * size
    // Allocation succeeded.  Let's check if it actually has the size it should.
    expect-equals '*' str[size - 1]
    expect-equals '*' str[0]
  if exception:
    expect-equals "OUT_OF_RANGE" exception
