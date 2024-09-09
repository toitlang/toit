// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

// The test-warnings function is on the top, as the health tests record
// the line numbers of the warnings. Having the function earlier makes it
// less likely to change the line numbers when we change the test.
test-warnings:
  bytes := #[-1, 256]
  expect bytes is ByteArray_
  expect-equals 255 bytes[0]
  expect-equals 0 bytes[1]

  bytes = #[-1, -1, -1, -1, -1, -1]
  expect bytes is CowByteArray_
  bytes.do: expect-equals 255 it

main:
  test-basic
  test-warnings
  test-slices-succeed
  test-slices-fail
  test-cow-mutable-byte-content
  test-to-string
  test-hash-code
  test-construction

test-basic:
  2.repeat:
    bytes := #[1, 2]
    expect bytes is ByteArray
    expect-equals 1 bytes[0]
    expect-equals 2 bytes[1]
    bytes[0] = 3
    expect bytes is ByteArray
    expect-equals 3 bytes[0]
    expect-equals 2 bytes[1]

  2.repeat:
    bytes := #[1, 2, 3, 4, 5, 6]  // Now a CowByteArray
    expect bytes is CowByteArray_
    expect bytes is ByteArray
    expect-equals 1 bytes[0]
    expect-equals 2 bytes[1]
    expect-equals 6 bytes[5]
    target := ByteArray 10
    target.replace 0 bytes
    bytes.size.repeat:
      expect-equals it + 1 target[it]
    bytes[0] = 3
    expect bytes is ByteArray
    expect-equals 3 bytes[0]
    expect-equals 2 bytes[1]
    target.replace 0 bytes
    bytes.size.repeat:
      if it == 0: expect-equals 3 target[it]
      else:       expect-equals it + 1 target[it]

  h := 'h'
  e := 'e'
  l := 'l'
  o := 'o'
  // The following is not a CowByteArray, as it is filled with variables.
  bytes := #[h, e, l, l, o]
  expect bytes is ByteArray_
  expect-equals "hello" bytes.to-string
  test-index-of bytes

  // If we use the char literals, we get a CoW byte array.
  bytes = #['h', 'e', 'l', 'l', 'o']
  expect bytes is CowByteArray_
  expect-equals "hello" bytes.to-string
  test-index-of bytes
  bytes[0] = 'w'
  bytes[1] = 'o'
  bytes[2] = 'r'
  bytes[3] = 'l'
  bytes[4] = 'd'
  expect-equals "world" bytes.to-string

  empty := #[]
  expect empty.is-empty

  x := 256
  bytes = #[x]
  expect-equals 0 bytes[0]

  x = -1
  bytes = #[x]
  expect-equals 255 bytes[0]

  // Make sure the inferred type of byte-array literals is `ByteArray`.
  // We want the type-checker to say that these types all agree. The test
  // should not have any warnings on these lines.
  // The health-check of the repository ensures that we won't accidentally
  // add warnings at a later point.
  b := #[0]  // 'b' is of the inferred type of `#[0]`.
  b = #[]  // Not a CoW byte array, because it's zero length.
  b = #[1 + 1]
  b = ByteArray 1
  b = #[1, 2, 3, 4, 5]  // We must be able to assign a CowByteArray_ to it.

  b2 := #[1, 2, 3, 4, 5]  // 'b2' is the inferred type of the CoW byte array.
  b2 = #[0]  // We must be able to assign a different ByteArray to it.
  b2 = #[]
  b2 = #[1 + 1]
  b2 = ByteArray 1

  b3 /ByteArray := ByteArray 0
  b3 = #[0]
  b3 = #[1, 2, 3, 4, 5]
  b3 = #[]
  b3 = #[1 + 1]

  b4 := ByteArray 0
  b4 = #[0]
  b4 = #[1, 2, 3, 4, 5]
  b4 = #[]
  b4 = #[1 + 1]

  b5 := #[]
  b5 = #[0]
  b5 = #[1, 2, 3, 4, 5]
  b5 = ByteArray 0
  b5 = #[1 + 1]

test-slices-succeed:
  for i := 0; i < 4; i++:
    bytes := #[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14]
    bytes-long := #[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
    if i == 0:
      // Test on CowByteArray_.
      expect bytes is CowByteArray_
    if i == 1:
      // Test on normal ByteArray_.
      bytes = bytes.copy
      expect bytes is ByteArray_
    else if i == 2:
      // Test on slice of CowByteArray_
      bytes = bytes-long[..bytes.size]
    else if i == 3:
      // Test on slice of ByteArray_
      bytes = bytes-long.copy[..bytes.size]

    slice := bytes[..]
    expect-bytes-equal bytes slice
    slice[0] = 11
    expect-equals 11 bytes[0]
    bytes[1] = 22
    expect-equals 22 slice[1]

    slice = bytes[1..]
    expect-equals bytes.size - 1 slice.size
    expect-equals 22 slice[0]
    slice[0] = 222
    expect-equals 222 bytes[1]

    slice = bytes[..3]
    expect-equals 3 slice.size
    expect-equals 3 slice[2]
    bytes[2] = 33
    expect-equals 33 slice[2]

    slice = bytes[3..5]
    expect-equals 2 slice.size
    expect-equals 4 slice[0]
    slice[0] = 44
    expect-equals 44 bytes[3]

    bytes[0] = 'h'
    bytes[1] = 'e'
    bytes[2] = 'l'
    bytes[3] = 'l'
    bytes[4] = 'o'

    slice = bytes[..5]
    // We are allowed to use 'to' if the source is empty.
    slice.replace 5 bytes 3 3

    slice = bytes[..5]
    // Make sure the primitive call works.
    str := slice.to-string
    expect-equals "hello" str
    test-index-of slice

test-slices-fail:
  cow := #[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14]
  rw := cow.copy
  slice := rw[1 .. rw.size - 1]

  [cow, rw, slice].do: | bytes |
    expect-throw "OUT_OF_BOUNDS": bytes[.. bytes.size + 1]
    expect-throw "OUT_OF_BOUNDS": bytes[..-1]
    expect-throw "OUT_OF_BOUNDS": bytes[-1..]
    expect-throw "OUT_OF_BOUNDS": bytes[1..0]

cow-byte-array := #[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95, 96, 97, 98, 99, 100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 111, 112, 113, 114, 115, 116, 117, 118, 119, 120, 121, 122, 123, 124, 125, 126, 127]
test-cow-mutable-byte-content:
  "test".write-to-byte-array cow-byte-array 0
  expect-bytes-equal "test".to-byte-array cow-byte-array[0..4]

test-index-of bytes/ByteArray:
  // The content is 'hello'

  expect-equals
    0
    bytes.index-of 'h'
  expect-equals
    4
    bytes.index-of 'o'
  expect-equals
    -1
    bytes.index-of 'p'
  expect-equals
    2
    bytes.index-of 'l'
  expect-equals
    3
    bytes.index-of 'l' --from=3
  expect-equals
    -1
    bytes.index-of 'l' --to=2
  expect-equals
    2
    bytes.index-of 'l' --to=3
  expect-throw "OUT_OF_BOUNDS": bytes.index-of 'h' --from=-1
  expect-throw "OUT_OF_BOUNDS": bytes.index-of 'h' --to=bytes.size + 1
  expect-throw "OUT_OF_BOUNDS": bytes.index-of 'h' --from=3 --to=2

test-to-string:
  HEST ::= #[0x48, 0x65, 0x73, 0x74]
  // Simple case.
  expect-equals "Hest"
    HEST.to-string
  expect-equals "Hest"
    HEST.to-string-non-throwing

  // Explicit from and to.
  expect-equals "Hest"
    HEST.to-string 0 4
  expect-equals "Hest"
    HEST.to-string-non-throwing 0 4

  // Trunctaed from and to.
  expect-equals "Hes"
    HEST.to-string 0 3
  expect-equals "Hes"
    HEST.to-string-non-throwing 0 3

  // Out of bounds `to`.
  expect-throw "OUT_OF_BOUNDS":
    HEST.to-string 0 5
  expect-throw "OUT_OF_BOUNDS":
    HEST.to-string-non-throwing 0 5

  // Out of bounds `from`.
  expect-throw "OUT_OF_BOUNDS":
    HEST.to-string -1 4
  expect-throw "OUT_OF_BOUNDS":
    HEST.to-string-non-throwing -1 4

  // Reversed `from` and `to`.
  expect-throw "OUT_OF_BOUNDS":
    HEST.to-string 3 2
  expect-throw "OUT_OF_BOUNDS":
    HEST.to-string-non-throwing 3 2

test-hash-code:
  expect-equals
    "".hash-code
    #[].hash-code

  expect-equals
    "abc".hash-code
    #['a', 'b', 'c'].hash-code

  256.repeat:
    ba := #[0, 1, 2]
    old := ba.hash-code
    if it != 1:
      ba[1] = it
      new := ba.hash-code
      expect-not-equals old new
    ba2 := #[0, it, 2]
    expect-equals
      ba.hash-code
      ba2.hash-code

  a := List 30: #[42, 103, random 256, 9]
  a.size.repeat: | x |
    a.size.repeat: | y |
      eq := a[x] == a[y]
      if eq:
        expect-equals a[x][2] a[y][2]
        expect-equals (a[x].hash-code) (a[y].hash-code)
      else:
        expect-not-equals a[x][2] a[y][2]

  ba := #[23, 3, 2, 5, 255, 2, 3, 2, 3, 2, 5, 2, 5, 1, 5, 1, 5, 1, 5, 81, 150, 234, 52, 3, 5, 7, 9, 10, 234, 2, 5, 8, 9, 2, 0, 53, 23, 2, 1, 2, 3]
  expect-equals
    ba[1..ba.size - 1].hash-code
    (ba.copy 1 (ba.size - 1)).hash-code

  ba = ByteArray 256: random 256
  expect-equals
    ba[1..ba.size - 1].hash-code
    (ba.copy 1 (ba.size - 1)).hash-code

test-construction -> none:
  ba := ByteArray 5 --initial=42
  expect-equals #[42, 42, 42, 42, 42] ba

  ba = ByteArray 5
  expect-equals #[0, 0, 0, 0, 0] ba
