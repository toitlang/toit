// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .checksum
import .crc as crc
import ..io as io

/** 32-bit Cyclic redundancy check (CRC-32). */

/**
Computes the CRC32 checksum of the given $data.

Returns the checksum as a 4 element byte array in little-endian order.

Deprecated.  Use $crc.crc32 or $crc.Crc32 instead.
*/
crc32 data/io.Data from/int=0 to/int=data.byte-size -> ByteArray:
  state := crc.Crc.little-endian 32
      --polynomial=0xEDB88320
      --initial-state=0xffff_ffff
      --xor-result=0xffff_ffff
  state.add data from to
  return state.get

/**
CRC-32 checksum state.

Deprecated.  Use $crc.Crc32 instead.
*/
class Crc32 extends crc.Crc:
  constructor:
    super.little-endian 32
        --polynomial=0xEDB88320
        --initial-state=0xffff_ffff
        --xor-result=0xffff_ffff
