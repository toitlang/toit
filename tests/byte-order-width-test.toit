// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import io show LITTLE-ENDIAN BIG-ENDIAN
import system

// The byte-order primitives take the width as a C int. The signed readers
// and put-uint-little-endian must check it before doing arithmetic on it:
// `width - 1` overflows for the smallest int (undefined behavior, which a
// UBSan build of the VM reports).

INT32-MIN ::= -2147483648
INT32-MAX ::= 2147483647

// The primitives, without the fallback code of the io library.
read-int-le unused bytes/ByteArray width/int offset/int:
  #primitive.core.read-int-little-endian: return it

read-int-be unused bytes/ByteArray width/int offset/int:
  #primitive.core.read-int-big-endian: return it

put-uint-le unused bytes/ByteArray width/int offset/int value/int:
  #primitive.core.put-uint-little-endian: return it

main:
  test-invalid-widths
  test-valid-widths

test-invalid-widths:
  bytes := #[0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8a]
  widths := [INT32-MIN, INT32-MIN + 1, -2, -1, 0, 9, 10, INT32-MAX]
  widths.do: | width/int |
    // On 32-bit VMs the extreme widths aren't smis.
    is-smi := system.BITS-PER-WORD == 64 or -1073741824 <= width <= 1073741823
    expected := is-smi ? "OUT_OF_BOUNDS" : "OUT_OF_RANGE"
    [0, 1, 10].do: | offset/int |
      expect-equals expected (read-int-le null bytes width offset)
      expect-equals expected (read-int-be null bytes width offset)
      target := ByteArray 10
      expect-equals expected (put-uint-le null target width offset 0)
      expect-equals (ByteArray 10) target

  // Widths that don't fit a C int.
  [INT32-MIN - 1, INT32-MAX + 1].do: | width/int |
    expect-equals "OUT_OF_RANGE" (read-int-le null bytes width 0)
    expect-equals "OUT_OF_RANGE" (read-int-be null bytes width 0)
    expect-equals "OUT_OF_RANGE" (put-uint-le null (ByteArray 10) width 0 0)

test-valid-widths:
  bytes := #[0x81, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x88]
  expect-equals -127 (read-int-le null bytes 1 0)
  expect-equals -127 (read-int-be null bytes 1 0)
  expect-equals 0x0281 (read-int-le null bytes 2 0)
  expect-equals -32510 (read-int-be null bytes 2 0)
  little-8 := -8644934341102468479  // 0x8807060504030281 as a signed 64-bit integer.
  big-8 := -9150748177064392824  // 0x8102030405060788 as a signed 64-bit integer.
  expect-equals little-8 (read-int-le null bytes 8 0)
  expect-equals big-8 (read-int-be null bytes 8 0)
  expect-equals -120 (read-int-le null bytes 1 7)
  expect-equals "OUT_OF_BOUNDS" (read-int-le null bytes 2 7)
  expect-equals "OUT_OF_BOUNDS" (read-int-be null bytes 2 7)

  expect-equals little-8 (LITTLE-ENDIAN.read-int bytes 8 0)
  expect-equals big-8 (BIG-ENDIAN.read-int bytes 8 0)

  target := ByteArray 9
  expect-null (put-uint-le null target 1 0 0x1ff)
  expect-equals #[0xff, 0, 0, 0, 0, 0, 0, 0, 0] target
  expect-null (put-uint-le null target 8 1 -2)
  expect-equals #[0xff, 0xfe, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff] target
  expect-equals "OUT_OF_BOUNDS" (put-uint-le null target 2 8 0)

  target = ByteArray 4
  LITTLE-ENDIAN.put-uint target 3 1 0x123456
  expect-equals #[0, 0x56, 0x34, 0x12] target
