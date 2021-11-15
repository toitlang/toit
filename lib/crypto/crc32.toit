// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .checksum
import .crc

/** 32-bit Cyclic redundancy check (CRC-32). */

/**
Computes the CRC32 checksum of the given $data.

The $data must be a string or byte array.
Returns the checksum as a 4 element byte array in little-endian order.
*/
crc32 data from/int=0 to/int=data.size -> ByteArray:
  return checksum Crc32 data from to

CRC32_TABLE_ ::= [
  0, 0x1db71064, 0x3b6e20c8, 0x26d930ac, 0x76dc4190, 0x6b6b51f4, 0x4db26158,
  0x5005713c, 0xedb88320, 0xf00f9344, 0xd6d6a3e8, 0xcb61b38c, 0x9b64c2b0,
  0x86d3d2d4, 0xa00ae278, 0xbdbdf21c ]

/** CRC-32 checksum state. */
class Crc32 extends CrcBase:
  /** Constructs a CRC-32 state. */
  constructor:
    super 0xffffffff

  crc_table_ -> List: return CRC32_TABLE_

  /**
  See $super.

  Returns the CRC32 checksum as a 4 element byte array in little-endian order.
  */
  get -> ByteArray:
    checksum := sum_ ^ 0xffffffff
    return ByteArray 4: (checksum >> (8 * it)) & 0xff
