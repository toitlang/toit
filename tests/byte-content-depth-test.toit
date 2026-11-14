// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

// The wrapped object of a byte-array slice is an ordinary field and can be
// another slice. Primitives that take the bytes of a slice must not recurse
// through an arbitrarily long chain of them (and overflow the C stack).

main:
  test-shallow
  test-deep

blob-equals a b:
  #primitive.core.blob-equals

byte-array-replace target index source from to:
  #primitive.core.byte-array-replace

test-shallow:
  // A slice of a copy-on-write byte array, as the core library creates it.
  cow := #[1, 2, 3, 4]
  slice := cow[1..3]
  expect-equals #[2, 3] slice
  expect (blob-equals slice #[2, 3])
  byte-array-replace slice 0 #[7] 0 1
  expect-equals #[7, 3] slice

  // A few nested slices.
  bytes := #[1, 2, 3, 4, 5]
  nested := ByteArraySlice_ (ByteArraySlice_ (ByteArraySlice_ bytes 1 5) 1 4) 1 3
  expect (blob-equals nested #[4, 5])
  byte-array-replace nested 0 #[9, 9] 0 2
  expect-equals #[1, 2, 3, 9, 9] bytes

test-deep:
  bytes := ByteArray 4
  chain := bytes
  1_000_000.repeat: chain = ByteArraySlice_ chain 0 1
  expect-throw "WRONG_OBJECT_TYPE": blob-equals chain #[0]
  expect-throw "WRONG_OBJECT_TYPE": byte-array-replace chain 0 #[1] 0 1
  expect-throw "WRONG_BYTES_TYPE": byte-array-replace bytes 0 chain 0 1
  expect-equals 0 bytes[0]
