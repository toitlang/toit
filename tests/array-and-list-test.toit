// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  test-byte-array
  test-array
  test-large-array-do
  test-matrix
  test-join

test-join:
  a := []
  expect-equals "" (a.join "")
  expect-equals "" (a.join "foo")
  a = ["foo"]
  expect-equals "foo" (a.join "")
  expect-equals "foo" (a.join "bar")
  a = ["foo", "bar"]
  expect-equals "foobar" (a.join "")
  expect-equals "foo,bar" (a.join ",")
  expect-equals "foo, bar" (a.join ", ")
  a = ["foo", "bar", "baz"]
  expect-equals "foobarbaz" (a.join "")
  expect-equals "foo,bar,baz" (a.join ",")
  expect-equals "foo, bar, baz" (a.join ", ")

  a = ["123", "1.25", "hello"]
  expect-equals "123, 1.25, hello" (a.join ", ")

  a = []
  star-block := : "*$it.stringify*"
  expect-equals "" (a.join "" star-block)
  expect-equals "" (a.join "foo" star-block)
  a = ["foo"]
  expect-equals "*foo*" (a.join "" star-block)
  expect-equals "*foo*" (a.join "bar" star-block)
  a = ["foo", "bar"]
  expect-equals "*foo**bar*" (a.join "" star-block)
  expect-equals "*foo*,*bar*" (a.join "," star-block)
  expect-equals "*foo*, *bar*" (a.join ", " star-block)
  a = ["foo", "bar", "baz"]
  expect-equals "*foo**bar**baz*" (a.join "" star-block)
  expect-equals "*foo*,*bar*,*baz*" (a.join "," star-block)
  expect-equals "*foo*, *bar*, *baz*" (a.join ", " star-block)

  a = ["123", "1.25", "hello"]
  expect-equals "*123*, *1.25*, *hello*" (a.join ", " star-block)

test-byte-array:
  a := ByteArray 10
  expect a.size == 10

  i := 0
  while i < a.size:
    a[i] = i * 2
    i++

  expect-equals (5 * 2) a[5]
  expect-equals (6 * 2) a[6]

  i = 0
  while i < a.size:
    a[i] = a[i] * 2
    i++

  expect-equals (6 * 2 * 2) a[6]
  expect-equals (7 * 2 * 2) a[7]

  bytes := ByteArray 3: it + 1
  expect-equals "#[0x01, 0x02, 0x03]" bytes.stringify
  bytes = ByteArray 51: it
  expected := "#["
      + "0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, "
      + "0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f, "
      + "0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x2f, "
      + "0x30, 0x31, ...]"
  expect-equals expected bytes.stringify

  bytes = #['a', 'b', 'c']
  expect bytes.is-valid-string-content
  expect (bytes.is-valid-string-content 1)
  expect (bytes.is-valid-string-content 2 3)
  bytes[1] = 0b1110_0000
  expect-not bytes.is-valid-string-content
  expect (bytes.is-valid-string-content 0 1)
  expect (bytes.is-valid-string-content 2 3)
  bytes[2] = 0b1110_0000
  expect-not bytes.is-valid-string-content
  expect (bytes.is-valid-string-content 0 1)
  expect-not (bytes.is-valid-string-content 2 3)

  // Must be long enough to be a CoW byte array.
  illegal := #[0xff, 'a', 0xff, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  expect-not illegal.is-valid-string-content
  expect (illegal.is-valid-string-content 1 2)
  expect-not (illegal.is-valid-string-content 2 3)

test-array:
  a := Array_ 10
  expect a.size == 10

  i := 0
  while i < a.size:
    a[i] = i * 2
    i++

  expect-equals (5 * 2) a[5]
  expect-equals (6 * 2) a[6]

  i = 0
  while i < a.size:
    a[i] = a[i] * 2
    i++

  expect-equals (6 * 2 * 2) a[6]
  expect-equals (7 * 2 * 2) a[7]

  a.size.repeat:
    a[it] = 100 - it

  sorted := a.sort
  expect (not a.is-sorted)
  expect sorted.is-sorted

ARRAYLET-SIZE ::= LargeArray_.ARRAYLET-SIZE
FILLER := 3.1415


test-large-array-do:
 10.repeat:
  sizes := [ 0, 1, 499, 500, 501, 999, 1000, 1001, 9999, 10000, 10001 ]
  sizes.do: | size |
    sizes.do: | new-size |
      sizes.do: | copy-size |
        array := Array_ size
        expect-equals
            size <= ARRAYLET-SIZE
            array is SmallArray_

        count := 0
        array.do: count++
        expect-equals size count

        // Fill with non-null values.
        array.size.repeat: array[it] = it

        sum := 0
        array.do:
          expect-equals it array[it]
          sum += it
        expect-equals
            (array.size * (array.size - 1)) / 2
            sum

        if copy-size <= size:
          copy := array.resize-for-list_ copy-size new-size FILLER

          expect-equals new-size copy.size

          expect-equals
              new-size <= ARRAYLET-SIZE
              copy is SmallArray_

          // Verify that the arraylets were reused.
          if array is LargeArray_ and copy is LargeArray_:
            (min (size / ARRAYLET-SIZE) (new-size / ARRAYLET-SIZE)).repeat:
              expect
                  identical
                      (array as LargeArray_).vector_[it]
                      (copy as LargeArray_).vector_[it]
          // Verify that values were copied.
          copy-edge := min size (min new-size copy-size)
          for i := 0; i < copy-edge; i++:
            expect-equals i copy[i]
          // Verify filler was used.
          for i := copy-edge; i < new-size; i++:
            expect-equals FILLER copy[i]

test-matrix:
  matrix := Matrix
  matrix[0, 0] = 00
  matrix[0, 1] = 01
  matrix[1, 0] = 10
  matrix[1, 1] = 11
  expect matrix[0, 0] == 00
  expect matrix[0, 1] == 01
  expect matrix[1, 0] == 10
  expect matrix[1, 1] == 11

  a := [ ]
  expect-equals 0 a.size

  a = [ 2, 3 ]
  expect-equals 2 a.size
  expect-equals 2 a[0]
  expect-equals 3 a[1]

  a = [ 3, 4, ]
  expect-equals 2 a.size
  expect-equals 3 a[0]
  expect-equals 4 a[1]

  expect [1,2] == [1,2]
  expect-equals
      6
      [1, 2, 3].reduce --initial=0: | sum e | sum + e

class Matrix:
  data := List 4
  operator [] x y:
    return data[x * 2 + y]
  operator []= x y v:
    return data[x * 2 + y] = v
