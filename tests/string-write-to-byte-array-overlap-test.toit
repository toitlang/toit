// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

// Tests that the string-write-to-byte-array primitive handles the case where
// the source and the destination are the same byte array and the ranges
// overlap.

main:
  [10, 100, 5000].do: | size |
    shift := size / 10
    length := size / 2
    // Copy to a higher index.
    test-overlap size 0 length shift
    // Copy to a lower index.
    test-overlap size shift (shift + length) 0
    // Overlap by a single byte.
    test-overlap size 0 length (length - 1)
    test-overlap size (length - 1) (2 * length - 1) 0

test-overlap size/int from/int to/int dest-index/int:
  bytes := ByteArray size: it & 0xff
  expected := memmove (ByteArray size: it & 0xff) from to dest-index
  write-primitive bytes bytes from to dest-index
  expect-bytes-equal expected bytes

/** Computes the expected result of a memmove in Toit. */
memmove bytes/ByteArray from/int to/int dest-index/int -> ByteArray:
  copy := List (to - from): bytes[from + it]
  copy.size.repeat: bytes[dest-index + it] = copy[it]
  return bytes

write-primitive source dest/ByteArray from/int to/int dest-index/int:
  #primitive.core.string-write-to-byte-array
