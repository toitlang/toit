// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import binary show *

main:
  test_little_endian
  test_big_endian
  test_exception

expect_throws name [code]:
  expect_equals
    name
    catch code

expect_throws [code]:
  e := catch:
    code.call
    throw null
  if not e:
    throw "Unexpectedly did not throw"

test_little_endian:
  list := [1, 2, 3, 4, 5, 6, 7, 8, 0]
  array := ByteArray list.size: list[it]

  expect_equals 0x201 (LITTLE_ENDIAN.int16 array 0)
  expect_equals 0x302 (LITTLE_ENDIAN.int16 array 1)
  expect_equals 0x706 (LITTLE_ENDIAN.int16 array 5)
  expect_equals 0x807 (LITTLE_ENDIAN.int16 array 6)
  expect_equals 0x40302 (LITTLE_ENDIAN.int24 array 1)
  expect_equals 0x80706 (LITTLE_ENDIAN.int24 array 5)

  expect_equals 0x201 (LITTLE_ENDIAN.uint16 array 0)
  expect_equals 0x302 (LITTLE_ENDIAN.uint16 array 1)
  expect_equals 0x706 (LITTLE_ENDIAN.uint16 array 5)
  expect_equals 0x807 (LITTLE_ENDIAN.uint16 array 6)
  expect_equals 0x40302 (LITTLE_ENDIAN.uint24 array 1)
  expect_equals 0x80706 (LITTLE_ENDIAN.uint24 array 5)

  LITTLE_ENDIAN.put_uint16 array 0 -1
  expect_equals -1 (LITTLE_ENDIAN.int16 array 0)
  expect_equals 0xffff (LITTLE_ENDIAN.uint16 array 0)

  LITTLE_ENDIAN.put_uint24 array 0 -1
  expect_equals -1 (LITTLE_ENDIAN.int16 array 0)
  expect_equals 0xffff (LITTLE_ENDIAN.uint16 array 0)
  expect_equals -1 (LITTLE_ENDIAN.int24 array 0)
  expect_equals 0xff_ffff (LITTLE_ENDIAN.uint24 array 0)

  LITTLE_ENDIAN.put_uint24 array 0 0x030201

  expect_equals 67305985 (LITTLE_ENDIAN.int32 array 0)
  expect_equals 84148994 (LITTLE_ENDIAN.int32 array 1)
  expect_equals 100992003 (LITTLE_ENDIAN.int32 array 2)
  expect_equals 117835012 (LITTLE_ENDIAN.int32 array 3)
  expect_equals 134678021 (LITTLE_ENDIAN.int32 array 4)

  LITTLE_ENDIAN.put_int64 array 0 9223372036854775807
  expect_equals 4294967295 (LITTLE_ENDIAN.uint32 array 0)
  expect_equals 2147483647 (LITTLE_ENDIAN.uint32 array 4)

  LITTLE_ENDIAN.put_int64 array 0 -8444249301319680000
  expect_equals -30000 (LITTLE_ENDIAN.int16 array 6)
  expect_equals 0 (LITTLE_ENDIAN.int16 array 0)

  LITTLE_ENDIAN.put_float64 array 0 1.0
  expect_equals 0 (LITTLE_ENDIAN.int32 array 0)
  expect_equals 0x3ff00000 (LITTLE_ENDIAN.int32 array 4)

  test_either_endian LITTLE_ENDIAN array 0
  array[0] = 99
  test_either_endian LITTLE_ENDIAN array 1
  expect_equals 99 array[0]

test_exception:
  array := #[0, 1, 2, 3, 4, 5, 6, 7]
  expect_throws "OUT_OF_BOUNDS": LITTLE_ENDIAN.int64 array 1
  expect_throws "OUT_OF_BOUNDS": LITTLE_ENDIAN.put_int64 array 1 0
  expect_throws "OUT_OF_BOUNDS": LITTLE_ENDIAN.int32 array 5
  expect_throws "OUT_OF_BOUNDS": LITTLE_ENDIAN.uint32 array 5
  expect_throws "OUT_OF_BOUNDS": LITTLE_ENDIAN.put_int32 array 5 0
  expect_throws "OUT_OF_BOUNDS": LITTLE_ENDIAN.int16 array 7
  expect_throws "OUT_OF_BOUNDS": LITTLE_ENDIAN.uint16 array 7
  expect_throws "OUT_OF_BOUNDS": LITTLE_ENDIAN.put_int16 array 7 0
  expect_throws "OUT_OF_BOUNDS": LITTLE_ENDIAN.int8 array 8
  expect_throws "OUT_OF_BOUNDS": LITTLE_ENDIAN.uint8 array 8
  expect_throws "OUT_OF_BOUNDS": LITTLE_ENDIAN.put_int8 array 8 0
  expect_throws "OUT_OF_BOUNDS": BIG_ENDIAN.int64 array 1
  expect_throws "OUT_OF_BOUNDS": BIG_ENDIAN.put_int64 array 1 0
  expect_throws "OUT_OF_BOUNDS": BIG_ENDIAN.int32 array 5
  expect_throws "OUT_OF_BOUNDS": BIG_ENDIAN.uint32 array 5
  expect_throws "OUT_OF_BOUNDS": BIG_ENDIAN.put_int32 array 5 0
  expect_throws "OUT_OF_BOUNDS": BIG_ENDIAN.int16 array 7
  expect_throws "OUT_OF_BOUNDS": BIG_ENDIAN.uint16 array 7
  expect_throws "OUT_OF_BOUNDS": BIG_ENDIAN.put_int16 array 7 0
  expect_throws "OUT_OF_BOUNDS": BIG_ENDIAN.int8 array 8
  expect_throws "OUT_OF_BOUNDS": BIG_ENDIAN.uint8 array 8
  expect_throws "OUT_OF_BOUNDS": BIG_ENDIAN.put_int8 array 8 0

  big := ByteArray 16
  unused := null
  put_primitive_le unused big 0 1 42  // Write uint0, has no effect.
  put_primitive_be unused big 0 1 42  // Write uint0, has no effect.
  expect_equals 0 big[1]  // No change.
  put_primitive_le unused big 9 1 42  // Write uint72, not handled by primitive.
  expect_equals 0 big[1]  // No change.
  put_primitive_be unused big 9 1 42  // Write uint72, not handled by primitive.
  expect_equals 0 big[1]  // No change.

  huge := ByteArray 4096
  expect_throws: LITTLE_ENDIAN.put_int16 huge 0x3fff_ffff 0
  expect_throws: BIG_ENDIAN.put_int16 huge 0x3fff_ffff 0

put_primitive_le unused ba/ByteArray size/int offset/int value/int -> none:
  #primitive.core.put_uint_little_endian:
    return

put_primitive_be unused ba/ByteArray size/int offset/int value/int -> none:
  #primitive.core.put_uint_big_endian:
    return

test_big_endian:
  list2 := [8, 7, 6, 5, 4, 3, 2, 1, 0]
  array2 := ByteArray list2.size: list2[it]

  expect_equals 0x201 (BIG_ENDIAN.int16 array2 6)
  expect_equals 0x302 (BIG_ENDIAN.int16 array2 5)
  expect_equals 0x706 (BIG_ENDIAN.int16 array2 1)
  expect_equals 0x807 (BIG_ENDIAN.int16 array2 0)
  expect_equals 0x30201 (BIG_ENDIAN.int24 array2 5)

  expect_equals 0x201 (BIG_ENDIAN.uint16 array2 6)
  expect_equals 0x302 (BIG_ENDIAN.uint16 array2 5)
  expect_equals 0x706 (BIG_ENDIAN.uint16 array2 1)
  expect_equals 0x807 (BIG_ENDIAN.uint16 array2 0)
  expect_equals 0x30201 (BIG_ENDIAN.uint24 array2 5)

  array2[0] = 0x80
  expect_equals 0x8007 (BIG_ENDIAN.uint16 array2 0)
  expect_equals -(0x7FF9) (BIG_ENDIAN.int16 array2 0)
  expect_equals 0x800706 (BIG_ENDIAN.uint24 array2 0)
  expect_equals -(0x7FF8FA) (BIG_ENDIAN.int24 array2 0)

  BIG_ENDIAN.put_int64 array2 0 9223372036854775807
  expect_equals 4294967295 (BIG_ENDIAN.uint32 array2 4)
  expect_equals 2147483647 (BIG_ENDIAN.uint32 array2 0)

  BIG_ENDIAN.put_int64 array2 0 -8444249301319680000
  expect_equals -30000 (BIG_ENDIAN.int16 array2 0)
  expect_equals 0 (BIG_ENDIAN.int16 array2 6)

  BIG_ENDIAN.put_float64 array2 0 1.0
  expect_equals 0x3ff00000 (BIG_ENDIAN.int32 array2 0)
  expect_equals 0 (BIG_ENDIAN.int32 array2 4)

  test_either_endian BIG_ENDIAN array2 0
  array2[0] = 99
  test_either_endian BIG_ENDIAN array2 1

test_either_endian either array offset:
  either.put_uint32 array offset 0
  expect_equals 0 (either.int32 array offset)

  either.put_uint32 array offset 1234567890
  expect_equals 1234567890 (either.int32 array offset)

  either.put_uint32 array offset -1
  expect_equals -1 (either.int32 array offset)
  expect_equals 4294967295 (either.uint32 array offset)

  either.put_uint32 array offset -1234567890
  expect_equals -1234567890 (either.int32 array offset)

  either.put_uint32 array offset 0x3fffffff
  expect_equals 0x3fffffff (either.int32 array offset)
  expect_equals 0x3fffffff (either.uint32 array offset)

  either.put_uint32 array offset 0x40000000
  expect_equals 0x40000000 (either.int32 array offset)
  expect_equals 0x40000000 (either.uint32 array offset)

  either.put_uint32 array offset -(0x3fffffff)
  expect_equals -(0x3fffffff) (either.int32 array offset)
  expect_equals 0xc0000001 (either.uint32 array offset)

  either.put_uint32 array offset -(0x40000000)
  expect_equals -(0x40000000) (either.int32 array offset)
  expect_equals 0xc0000000 (either.uint32 array offset)

  either.put_uint32 array offset -(0x40000001)
  expect_equals -(0x40000001) (either.int32 array offset)
  expect_equals 0xbfffffff (either.uint32 array offset)

  either.put_int64 array offset 0x3fffffff
  expect_equals 0x3fffffff (either.int64 array offset)

  either.put_int64 array offset 0x40000000
  expect_equals 0x40000000 (either.int64 array offset)

  either.put_int64 array offset -(0x3fffffff)
  expect_equals -(0x3fffffff) (either.int64 array offset)

  either.put_int64 array offset -(0x40000000)
  expect_equals -(0x40000000) (either.int64 array offset)

  either.put_int64 array offset -(0x40000001)
  expect_equals -(0x40000001) (either.int64 array offset)

  either.put_int64 array offset 0
  expect_equals 0 (either.int64 array offset)

  either.put_int64 array offset -1
  expect_equals -1 (either.int64 array offset)

  either.put_int64 array offset 9223372036854775807
  expect_equals 9223372036854775807 (either.int64 array offset)

  either.put_int64 array offset 0x102030405060708
  expect_equals 0x102030405060708 (either.int64 array offset)

  either.put_float64 array offset 1.234
  expect_equals 1.234 (either.float64 array offset)

  either.put_float64 array offset float.INFINITY
  expect_equals float.INFINITY (either.float64 array offset)

  either.put_float32 array offset 0.5
  expect_equals 0.5 (either.float32 array offset)

  either.put_float32 array offset float.INFINITY
  expect_equals float.INFINITY (either.float32 array offset)
