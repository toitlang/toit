// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

MSB_ ::= 0b10000000
MASK_ ::= ~(MSB_-1)

/**
Deprecated.
*/
encode --offset=0 p/ByteArray i/int -> int:
  return encode p offset i

encode p/ByteArray offset/int i/int -> int:
  #primitive.core.varint_encode:
    // We hit this Toit fallback if the offset is out of bounds or the
    // worst-case analysis says we are too near the end of the byte array.
    if i & 0x7f == i:
      p[offset] = i
      return 1
    cnt := 0
    while i & MASK_ != 0:
      p[offset++] = i | MSB_
      i >>>= 7
      cnt++

    p[offset] = i
    return cnt + 1

/**
Deprecated.
*/
decode --offset/int=0 p/ByteArray -> int:
  return decode p offset

decode p/ByteArray offset/int -> int:
  #primitive.core.varint_decode:
    result := 0
    b := p[offset++]
    bits := 0
    while b & MSB_ != 0:
      result += (b & 0x7F) << bits
      bits += 7
      b = p[offset++]

    result += b << bits
    return result

// Returns the byte size of the varint on the position
byte_size --offset/int=0 p/ByteArray -> int:
  b := p[offset]
  i := 1
  while b & MSB_ != 0:
    b = p[offset + (i++)]
  return i

/// Returns the number of bytes used to encode $i.
size i/int -> int:
  return NUMBER_OF_BYTES_LOOKUP_[i.count_leading_zeros]

// This could perhaps be replaced by something like:
//   number_of_bytes_ clz_result/int:
//     if clz_result == 64: return 1
//     return (63 - clz_result) / 7 + 1
// But with our current optimizations that is slower.
NUMBER_OF_BYTES_LOOKUP_ ::= #[
    10,                        //                  0 leading zeros.
    9, 9, 9, 9, 9, 9, 9,       //                  1-7 leading zeros.
    8, 8, 8, 8, 8, 8, 8,       //                  8-14 leading zeros.
    7, 7, 7, 7, 7, 7, 7,       //                 15-21 leading zeros.
    6, 6, 6, 6, 6, 6, 6,       //                 22-28 leading zeros.
    5, 5, 5, 5, 5, 5, 5,       //                 29-35 leading zeros.
    4, 4, 4, 4, 4, 4, 4,       //                 36-42 leading zeros.
    3, 3, 3, 3, 3, 3, 3,       //                 43-49 leading zeros.
    2, 2, 2, 2, 2, 2, 2,       //                 50-56 leading zeros.
    1, 1, 1, 1, 1, 1, 1,       // 0x1 to 0x7f     57-63 leading zeros.
    1]                         // 0               64 leading zeros
