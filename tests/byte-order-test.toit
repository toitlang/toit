// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import io show LITTLE-ENDIAN BIG-ENDIAN ByteOrder

main:
  test-little-endian
  test-big-endian
  test-exception

expect-throws name [code]:
  expect-equals
    name
    catch code

expect-throws [code]:
  e := catch:
    code.call
    throw null
  if not e:
    throw "Unexpectedly did not throw"

test-little-endian:
  list := [1, 2, 3, 4, 5, 6, 7, 8, 0]
  array := ByteArray list.size: list[it]

  expect-equals 0x201 (LITTLE-ENDIAN.int16 array 0)
  expect-equals 0x302 (LITTLE-ENDIAN.int16 array 1)
  expect-equals 0x706 (LITTLE-ENDIAN.int16 array 5)
  expect-equals 0x807 (LITTLE-ENDIAN.int16 array 6)
  expect-equals 0x40302 (LITTLE-ENDIAN.int24 array 1)
  expect-equals 0x80706 (LITTLE-ENDIAN.int24 array 5)

  expect-equals 0x201 (LITTLE-ENDIAN.uint16 array 0)
  expect-equals 0x302 (LITTLE-ENDIAN.uint16 array 1)
  expect-equals 0x706 (LITTLE-ENDIAN.uint16 array 5)
  expect-equals 0x807 (LITTLE-ENDIAN.uint16 array 6)
  expect-equals 0x40302 (LITTLE-ENDIAN.uint24 array 1)
  expect-equals 0x80706 (LITTLE-ENDIAN.uint24 array 5)

  LITTLE-ENDIAN.put-uint16 array 0 -1
  expect-equals -1 (LITTLE-ENDIAN.int16 array 0)
  expect-equals 0xffff (LITTLE-ENDIAN.uint16 array 0)

  LITTLE-ENDIAN.put-uint24 array 0 -1
  expect-equals -1 (LITTLE-ENDIAN.int16 array 0)
  expect-equals 0xffff (LITTLE-ENDIAN.uint16 array 0)
  expect-equals -1 (LITTLE-ENDIAN.int24 array 0)
  expect-equals 0xff_ffff (LITTLE-ENDIAN.uint24 array 0)

  LITTLE-ENDIAN.put-uint24 array 0 0x030201

  expect-equals 67305985 (LITTLE-ENDIAN.int32 array 0)
  expect-equals 84148994 (LITTLE-ENDIAN.int32 array 1)
  expect-equals 100992003 (LITTLE-ENDIAN.int32 array 2)
  expect-equals 117835012 (LITTLE-ENDIAN.int32 array 3)
  expect-equals 134678021 (LITTLE-ENDIAN.int32 array 4)

  LITTLE-ENDIAN.put-int64 array 0 9223372036854775807
  expect-equals 4294967295 (LITTLE-ENDIAN.uint32 array 0)
  expect-equals 2147483647 (LITTLE-ENDIAN.uint32 array 4)

  LITTLE-ENDIAN.put-int64 array 0 -8444249301319680000
  expect-equals -30000 (LITTLE-ENDIAN.int16 array 6)
  expect-equals 0 (LITTLE-ENDIAN.int16 array 0)

  LITTLE-ENDIAN.put-float64 array 0 1.0
  expect-equals 0 (LITTLE-ENDIAN.int32 array 0)
  expect-equals 0x3ff00000 (LITTLE-ENDIAN.int32 array 4)

  test-either-endian LITTLE-ENDIAN array 0
  array[0] = 99
  test-either-endian LITTLE-ENDIAN array 1
  expect-equals 99 array[0]

test-exception:
  array := #[0, 1, 2, 3, 4, 5, 6, 7]
  expect-throws "OUT_OF_BOUNDS": LITTLE-ENDIAN.int64 array 1
  expect-throws "OUT_OF_BOUNDS": LITTLE-ENDIAN.put-int64 array 1 0
  expect-throws "OUT_OF_BOUNDS": LITTLE-ENDIAN.int32 array 5
  expect-throws "OUT_OF_BOUNDS": LITTLE-ENDIAN.uint32 array 5
  expect-throws "OUT_OF_BOUNDS": LITTLE-ENDIAN.put-int32 array 5 0
  expect-throws "OUT_OF_BOUNDS": LITTLE-ENDIAN.int16 array 7
  expect-throws "OUT_OF_BOUNDS": LITTLE-ENDIAN.uint16 array 7
  expect-throws "OUT_OF_BOUNDS": LITTLE-ENDIAN.put-int16 array 7 0
  expect-throws "OUT_OF_BOUNDS": LITTLE-ENDIAN.int8 array 8
  expect-throws "OUT_OF_BOUNDS": LITTLE-ENDIAN.uint8 array 8
  expect-throws "OUT_OF_BOUNDS": LITTLE-ENDIAN.put-int8 array 8 0
  expect-throws "OUT_OF_BOUNDS": BIG-ENDIAN.int64 array 1
  expect-throws "OUT_OF_BOUNDS": BIG-ENDIAN.put-int64 array 1 0
  expect-throws "OUT_OF_BOUNDS": BIG-ENDIAN.int32 array 5
  expect-throws "OUT_OF_BOUNDS": BIG-ENDIAN.uint32 array 5
  expect-throws "OUT_OF_BOUNDS": BIG-ENDIAN.put-int32 array 5 0
  expect-throws "OUT_OF_BOUNDS": BIG-ENDIAN.int16 array 7
  expect-throws "OUT_OF_BOUNDS": BIG-ENDIAN.uint16 array 7
  expect-throws "OUT_OF_BOUNDS": BIG-ENDIAN.put-int16 array 7 0
  expect-throws "OUT_OF_BOUNDS": BIG-ENDIAN.int8 array 8
  expect-throws "OUT_OF_BOUNDS": BIG-ENDIAN.uint8 array 8
  expect-throws "OUT_OF_BOUNDS": BIG-ENDIAN.put-int8 array 8 0

  big := ByteArray 16
  unused := null
  put-primitive-le unused big 0 1 42  // Write uint0, has no effect.
  put-primitive-be unused big 0 1 42  // Write uint0, has no effect.
  expect-equals 0 big[1]  // No change.
  put-primitive-le unused big 9 1 42  // Write uint72, not handled by primitive.
  expect-equals 0 big[1]  // No change.
  put-primitive-be unused big 9 1 42  // Write uint72, not handled by primitive.
  expect-equals 0 big[1]  // No change.

  huge := ByteArray 4096
  expect-throws: LITTLE-ENDIAN.put-int16 huge 0x3fff_ffff 0
  expect-throws: BIG-ENDIAN.put-int16 huge 0x3fff_ffff 0

put-primitive-le unused ba/ByteArray size/int offset/int value/int -> none:
  #primitive.core.put-uint-little-endian:
    return

put-primitive-be unused ba/ByteArray size/int offset/int value/int -> none:
  #primitive.core.put-uint-big-endian:
    return

test-big-endian:
  list2 := [8, 7, 6, 5, 4, 3, 2, 1, 0]
  array2 := ByteArray list2.size: list2[it]

  expect-equals 0x201 (BIG-ENDIAN.int16 array2 6)
  expect-equals 0x302 (BIG-ENDIAN.int16 array2 5)
  expect-equals 0x706 (BIG-ENDIAN.int16 array2 1)
  expect-equals 0x807 (BIG-ENDIAN.int16 array2 0)
  expect-equals 0x30201 (BIG-ENDIAN.int24 array2 5)

  expect-equals 0x201 (BIG-ENDIAN.uint16 array2 6)
  expect-equals 0x302 (BIG-ENDIAN.uint16 array2 5)
  expect-equals 0x706 (BIG-ENDIAN.uint16 array2 1)
  expect-equals 0x807 (BIG-ENDIAN.uint16 array2 0)
  expect-equals 0x30201 (BIG-ENDIAN.uint24 array2 5)

  array2[0] = 0x80
  expect-equals 0x8007 (BIG-ENDIAN.uint16 array2 0)
  expect-equals -(0x7FF9) (BIG-ENDIAN.int16 array2 0)
  expect-equals 0x800706 (BIG-ENDIAN.uint24 array2 0)
  expect-equals -(0x7FF8FA) (BIG-ENDIAN.int24 array2 0)

  BIG-ENDIAN.put-int64 array2 0 9223372036854775807
  expect-equals 4294967295 (BIG-ENDIAN.uint32 array2 4)
  expect-equals 2147483647 (BIG-ENDIAN.uint32 array2 0)

  BIG-ENDIAN.put-int64 array2 0 -8444249301319680000
  expect-equals -30000 (BIG-ENDIAN.int16 array2 0)
  expect-equals 0 (BIG-ENDIAN.int16 array2 6)

  BIG-ENDIAN.put-float64 array2 0 1.0
  expect-equals 0x3ff00000 (BIG-ENDIAN.int32 array2 0)
  expect-equals 0 (BIG-ENDIAN.int32 array2 4)

  test-either-endian BIG-ENDIAN array2 0
  array2[0] = 99
  test-either-endian BIG-ENDIAN array2 1

test-either-endian either/ByteOrder array offset:
  either.put-uint32 array offset 0
  expect-equals 0 (either.int32 array offset)

  either.put-uint32 array offset 1234567890
  expect-equals 1234567890 (either.int32 array offset)

  either.put-uint32 array offset -1
  expect-equals -1 (either.int32 array offset)
  expect-equals 4294967295 (either.uint32 array offset)

  either.put-uint32 array offset -1234567890
  expect-equals -1234567890 (either.int32 array offset)

  either.put-uint32 array offset 0x3fffffff
  expect-equals 0x3fffffff (either.int32 array offset)
  expect-equals 0x3fffffff (either.uint32 array offset)

  either.put-uint32 array offset 0x40000000
  expect-equals 0x40000000 (either.int32 array offset)
  expect-equals 0x40000000 (either.uint32 array offset)

  either.put-uint32 array offset -(0x3fffffff)
  expect-equals -(0x3fffffff) (either.int32 array offset)
  expect-equals 0xc0000001 (either.uint32 array offset)

  either.put-uint32 array offset -(0x40000000)
  expect-equals -(0x40000000) (either.int32 array offset)
  expect-equals 0xc0000000 (either.uint32 array offset)

  either.put-uint32 array offset -(0x40000001)
  expect-equals -(0x40000001) (either.int32 array offset)
  expect-equals 0xbfffffff (either.uint32 array offset)

  either.put-int64 array offset 0x3fffffff
  expect-equals 0x3fffffff (either.int64 array offset)

  either.put-int64 array offset 0x40000000
  expect-equals 0x40000000 (either.int64 array offset)

  either.put-int64 array offset -(0x3fffffff)
  expect-equals -(0x3fffffff) (either.int64 array offset)

  either.put-int64 array offset -(0x40000000)
  expect-equals -(0x40000000) (either.int64 array offset)

  either.put-int64 array offset -(0x40000001)
  expect-equals -(0x40000001) (either.int64 array offset)

  either.put-int64 array offset 0
  expect-equals 0 (either.int64 array offset)

  either.put-int64 array offset -1
  expect-equals -1 (either.int64 array offset)

  either.put-int64 array offset 9223372036854775807
  expect-equals 9223372036854775807 (either.int64 array offset)

  either.put-int64 array offset 0x102030405060708
  expect-equals 0x102030405060708 (either.int64 array offset)

  either.put-float64 array offset 1.234
  expect-equals 1.234 (either.float64 array offset)

  either.put-float64 array offset -1.234
  expect-equals -1.234 (either.float64 array offset)

  either.put-float64 array offset float.INFINITY
  expect-equals float.INFINITY (either.float64 array offset)

  either.put-float32 array offset 0.5
  expect-equals 0.5 (either.float32 array offset)

  either.put-float32 array offset -0.5
  expect-equals -0.5 (either.float32 array offset)

  either.put-float32 array offset float.INFINITY
  expect-equals float.INFINITY (either.float32 array offset)
