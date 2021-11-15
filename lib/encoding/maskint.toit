// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import binary
import encoding.varint as varint

// ERR_INVALID_MASKINT ::= "INVALID_MASKINT"

// First byte of the encoding:
// 0xxx xxxx - 1 byte [2^0;2^7-1]
// 10xx xxxx - 2 bytes [2^7;2^14-1]
// 110x xxxx - 3 bytes [2^14;2^21-1]
// 1110 xxxx - 4 bytes [2^21;2^28-1]
// 1111 0xxx - 5 bytes [2^28;2^35-1]
// 1111 10xx - 6 bytes [2^35;2^42-1]
// 1111 110x - 7 bytes [2^42;2^49-1]
// 1111 1110 - 8 bytes [2^49;2^56-1]
// 1111 1111 - 9 bytes [2^56;2^64-1]

max_bytes_ n/int -> int:
  return (1 << (7 * n)) - 1

/**
Deprecated.
*/
encode --offset=0 p/ByteArray i/int -> int:
  return encode p offset i

encode p/ByteArray offset/int i/int -> int:
  if i & 0x7f == i:
    p[offset] = i
    return 1
  byte_size := size i
  binary.BIG_ENDIAN.put_uint p byte_size offset i
  p[offset] |= 0b1_1111_1110_0000_0000 >> byte_size
  return byte_size

/**
Deprecated.
*/
decode --offset/int=0 p/ByteArray -> int:
  return decode p offset

decode p/ByteArray offset/int -> int:
  p0 := p[offset]
  if p0 <= 127:
    return p0

  ones := count_ones_ p0

  result := 0
  if ones < 7:
    result = (p0 & (1 << (7 - ones)) - 1) << (8 * ones)
  result |= binary.BIG_ENDIAN.read_uint p ones offset + 1
  return result

/// Count the leading consecutive ones of i, treated as an 8 bit unsigned value.
count_ones_ i/int -> int:
  i = (i & 0xFF) ^ 0xFF
  return (count_leading_zeros i) - 56

/// Returns the number of bytes used to encode $i.
size i/int -> int:
  if i & 0x7f == i: return 1
  if i < 0: return 9
  return varint.NUMBER_OF_BYTES_LOOKUP_[count_leading_zeros i]

/// Returns the number of bytes used to encode the integer at the $offset position in the $p ByteArray.
byte_size --offset/int=0 p/ByteArray -> int:
  p0 := p[offset]
  ones := count_ones_ p0
  return ones + 1
