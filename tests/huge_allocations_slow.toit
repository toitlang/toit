// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  if platform != "FreeRTOS":
    test_huge_allocations

test_huge_allocations:
  [0x2000_0000, 0x4000_0000, 0x8000_0000].do: | base_size |
    4.repeat:
      size := base_size - (it + 1) * 4
      test_huge_byte_array size
      test_huge_string size

test_huge_byte_array size/int -> none:
  exception := catch:
    byte_array := ByteArray size
    // Allocation succeeded.  Let's check if it actually has the size it should.
    byte_array[size - 1] = 0x34
    byte_array[0] = 0x34
  if exception:
    expect_equals "OUT_OF_RANGE" exception

test_huge_string size/int -> none:
  exception := catch:
    str := "*" * size
    // Allocation succeeded.  Let's check if it actually has the size it should.
    expect_equals '*' str[size - 1]
    expect_equals '*' str[0]
  if exception:
    expect_equals "OUT_OF_RANGE" exception
