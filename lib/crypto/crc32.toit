// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .checksum
import .crc

/** 32-bit Cyclic redundancy check (CRC-32). */

/**
Computes the CRC32 checksum of the given $data.

The $data must be a string or byte array.
Returns the checksum as a 4 element byte array in little-endian order.

Deprecated.  Use crc.crc_32 or crc.Crc32 instead.
*/
crc32 data from/int=0 to/int=data.size -> ByteArray:
  crc := Crc.little_endian 32
      --polynomial=0xEDB88320
      --initial_state=0xffff_ffff
      --xor_result=0xffff_ffff
  crc.add data from to
  return crc.get

/**
CRC-32 checksum state.

Deprecated.  Use crc.Crc32 instead.
*/
class Crc32 extends Crc:
  constructor:
    super.little_endian 32
        --polynomial=0xEDB88320
        --initial_state=0xffff_ffff
        --xor_result=0xffff_ffff
