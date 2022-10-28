// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .checksum
import .crc

/**
16-bit Cyclic redundancy check (CRC-16/XMODEM).

https://en.wikipedia.org/wiki/XMODEM#XMODEM-CRC
*/

/**
Computes the CRC-16/XMODEM checksum of the given $data.

The $data must be a string or byte array.
Returns the checksum as a 2 element byte array in little-endian order.
*/
crc16 data from/int=0 to/int=data.size -> ByteArray:
  crc := Crc.big_endian 16 --polynomial=0x1021
  crc.add data from to
  return crc.get

/** CRC-16/XMODEM checksum state. */
class Crc16 extends Crc:
  constructor:
    super.big_endian 16 --polynomial=0x1021
