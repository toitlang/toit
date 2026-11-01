// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  test-string-write-to-byte-array

test-string-write-to-byte-array:
  dest := ByteArray 8
  write-primitive "abcd" dest 0 4 2
  expect-bytes-equal #[0, 0, 'a', 'b', 'c', 'd', 0, 0] dest
  write-primitive "abcd" dest 0 4 4
  expect-bytes-equal #[0, 0, 'a', 'b', 'a', 'b', 'c', 'd'] dest

  expect-throw "OUT_OF_BOUNDS": write-primitive "abcd" dest 0 4 -1
  expect-throw "OUT_OF_BOUNDS": write-primitive "abcd" dest 0 1 -4096
  expect-throw "OUT_OF_BOUNDS": write-primitive "abcd" dest 0 4 5
  expect-throw "OUT_OF_BOUNDS": write-primitive "abcd" dest 0 1 9
  expect-throw "OUT_OF_BOUNDS": write-primitive "abcd" dest 0 1 0x3fff_ffff
  expect-bytes-equal #[0, 0, 'a', 'b', 'a', 'b', 'c', 'd'] dest

  expect-throw "OUT_OF_BOUNDS": "abcd".write-to-byte-array dest -1
  expect-bytes-equal #[0, 0, 'a', 'b', 'a', 'b', 'c', 'd'] dest

write-primitive source/string dest/ByteArray from/int to/int dest-index/int:
  #primitive.core.string-write-to-byte-array
