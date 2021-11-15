// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .checksum

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
  return checksum Crc16 data from to

/** CRC-16/XMODEM checksum state. */
class Crc16 extends Checksum:
  sum_/int := 0

  /** See $super. */
  add data from/int to/int -> none:
    sum := sum_
    if data is string:
      (to - from).repeat:
        b := data.at --raw from + it
        sum = update_ sum b
    else:
      if data is not ByteArray: throw "WRONG_OBJECT_TYPE"
      (to - from).repeat:
        b := data[from + it]
        sum = update_ sum b
    sum_ = sum

  static update_ crc/int byte/int -> int:
    crc = crc ^ (byte << 8)
    8.repeat:
      if crc & 0x8000 == 0:
        crc <<= 1
      else:
        crc = (crc << 1) ^ 0x1021
    return crc

  /**
  See $super.

  Returns the CRC16 checksum as a 2 element byte array in little-endian order.
  */
  get -> ByteArray:
    checksum := sum_
    return ByteArray 2: (checksum >> (8 * it)) & 0xff
