// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import io
import io show ByteOrder LittleEndian BigEndian
export ByteOrder LittleEndian BigEndian

/**
Support for byte-order aware manipulation of byte arrays.

The little-endian byte order (generally used by all modern CPUs) stores the
  least-significant byte at the lowest address. Use $LITTLE-ENDIAN (a
  singleton instance of $LittleEndian) to manipulate byte arrays in this order.

The big-endian byte order stores the most-significant byte at the lowest
  address. It is frequently used in networking. Use $BIG-ENDIAN (a
  singleton instance of $BigEndian) to manipulate byte arrays in this order.
*/

/** Deprecated. Use $int.MIN-8 instead. */
INT8-MIN ::= -128
/** Deprecated. Use $int.MAX-8 instead. */
INT8-MAX ::= 127
/** Deprecated. Use $int.MIN-16 instead. */
INT16-MIN ::= -32_768
/** Deprecated. Use $int.MAX-16 instead. */
INT16-MAX ::= 32_767
/** Deprecated. Use $int.MIN-24 instead. */
INT24-MIN ::= -8_388_606
/** Deprecated. Use $int.MAX-24 instead. */
INT24-MAX ::= 8_388_607
/** Deprecated. Use $int.MIN-32 instead. */
INT32-MIN ::= -2_147_483_648
/** Deprecated. Use $int.MAX-32 instead. */
INT32-MAX ::= 2_147_483_647

/** Deprecated. Use $int.MAX-U8 instead. */
UINT8-MAX ::= 255
/** Deprecated. Use $int.MAX-U16 instead. */
UINT16-MAX ::= 65_535
/** Deprecated. Use $int.MAX-U24 instead. */
UINT24-MAX ::= 16777216
/** Deprecated. Use $int.MAX-U32 instead. */
UINT32-MAX ::= 4_294_967_295

/** Deprecated. Use $io.LITTLE-ENDIAN instead. */
LITTLE-ENDIAN/LittleEndian ::= io.LITTLE-ENDIAN
/** Deprecated. Use $io.BIG-ENDIAN instead. */
BIG-ENDIAN/BigEndian ::= io.BIG-ENDIAN

/**
Swaps the byte-order of all 16-bit integers in the $byte-array.
If the integers were in little-endian order they then are in big-endian byte order
If the integers were in big-endian order they then are in little-endian byte order.

Deprecated. Use $io.ByteOrder.swap-16 instead.
*/
byte-swap-16 byte-array/ByteArray -> none:
  io.ByteOrder.swap-16 byte-array

/**
Swaps the byte-order of all 32-bit integers in the $byte-array.
If the integers were in little-endian order they then are in big-endian byte order
If the integers were in big-endian order they then are in little-endian byte order.

Deprecated. Use $io.ByteOrder.swap-32 instead.
*/
byte-swap-32 byte-array/ByteArray -> none:
  io.ByteOrder.swap-32 byte-array
