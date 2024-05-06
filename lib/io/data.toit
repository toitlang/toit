// Copyright (C) 2024 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
A producer of bytes.

The most important implementations of this interface are
  $ByteArray and $string, which we call "Primitive IO Data". Any other data
  structure that implements this interface can still be used as byte-source
  for primitive operations but will first be converted to a byte array,
  using the $write-to-byte-array method. Some primitive operations will
  do this in a chunked way to avoid allocating a large byte array.

Since $Data objects can be instances of $ByteArray it is sometimes
  judicious to test if the given instance is already of class `ByteArray` before
  invoking $write-to-byte-array.
*/
interface Data:
  /** The amount of bytes that can be produced. */
  byte-size -> int

  /**
  Returns a slice of this data.
  */
  byte-slice from/int to/int -> Data

  /** Returns the byte at the given index. */
  byte-at index/int -> int

  /**
  Copies the bytes in the range $from-$to into the given $byte-array at the
    position $at.

  The parameter $from and the parameter $to must satisfy: 0 <= $from <= $to <= $byte-size.
  The parameter $at must satisfy 0 <= $at <= `bytes-size` where `bytes-size` is the
    size of the given $byte-array. It may only be equal to the size if $from == $to.

  # Inheritance
  Implementations are not required to check whether $at satisfies the required properties.
  Since writes to the given $byte-array are checked by the target, errors would automatically
    be reported then. This also means that the user might not get an error message if $at
    is not in bounds, but $from == $to. This is acceptable behavior.
  */
  write-to-byte-array byte-array/ByteArray --at/int from/int to/int -> none
