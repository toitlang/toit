// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import binary show LITTLE_ENDIAN
import .checksum

class MD5 extends Checksum:
  static SHIFTS_ ::= [
    07, 12, 17, 22, 07, 12, 17, 22, 07, 12, 17, 22, 07, 12, 17, 22, 05, 09, 14,
    20, 05, 09, 14, 20, 05, 09, 14, 20, 05, 09, 14, 20, 04, 11, 16, 23, 04, 11,
    16, 23, 04, 11, 16, 23, 04, 11, 16, 23, 06, 10, 15, 21, 06, 10, 15, 21, 06,
    10, 15, 21, 06, 10, 15, 21
  ]

  static NOISE_ ::= [
    0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a,
    0xa8304613, 0xfd469501, 0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
    0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821, 0xf61e2562, 0xc040b340,
    0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
    0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8,
    0x676f02d9, 0x8d2a4c8a, 0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
    0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70, 0x289b7ec6, 0xeaa127fa,
    0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
    0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92,
    0xffeff47d, 0x85845dd1, 0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
    0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391
  ]

  size_/int := 0
  buffer_/ByteArray? := ByteArray 64
  digest_/ByteArray? := null

  a_/int := 0x67452301
  b_/int := 0xefcdab89
  c_/int := 0x98badcfe
  d_/int := 0x10325476

  add data from/int to/int -> none:
    if not buffer_: throw "ALREADY_CLOSED"
    slice := data[from..to]
    add_bytes_ (slice is ByteArray ? slice : slice.to_byte_array)

  add_bytes_ bytes/ByteArray -> none:
    extra := bytes.size
    fullness := size_ & 0x3f
    size_ += extra

    // See if we can fit all the extra bytes into the buffer.
    buffer := buffer_
    n := 64 - fullness
    if extra < n:
      buffer.replace fullness bytes
      return

    // We have enough extra bytes to fill up the
    // buffer completely.
    buffer.replace fullness bytes 0 n
    add_chunk_ buffer

    // Run through the extra bytes and add the
    // full chunks we can find without copying
    // the bytes into the buffer.
    while true:
      next := n + 64
      if next > extra:
        // Save the last extra bytes in the buffer,
        // so we have them for the next add.
        buffer.replace 0 bytes[n..]
        return
      add_chunk_ bytes[n..next]
      n = next

  add_chunk_ chunk/ByteArray -> none:
    assert: chunk.size == 64
    noise := NOISE_
    shifts := SHIFTS_
    mask32 := 0xffff_ffff

    a := a_
    b := b_
    c := c_
    d := d_

    64.repeat: | i/int |
      e := ?
      f := ?
      if i < 16:
        e = (b & c) | ((~b & mask32) & d)
        f = i
      else if i < 32:
        e = (d & b) | ((~d & mask32) & c)
        f = ((5 * i) + 1) & 0xf
      else if i < 48:
        e = b ^ c ^ d
        f = ((3 * i) + 5) & 0xf
      else:
        e = c ^ (b | (~d & mask32))
        f = (7 * i) & 0xf

      t := d
      d = c
      c = b
      ae := (a + e) & mask32
      cf := LITTLE_ENDIAN.uint32 chunk (f << 2)
      nc := (noise[i] + cf) & mask32
      aenc := (ae + nc) & mask32
      shift := shifts[i]
      rotated := ((aenc << shift) & mask32) | (aenc >> (32 - shift))
      b = (b + rotated) & mask32
      a = t

    a_ = (a_ + a) & mask32
    b_ = (b_ + b) & mask32
    c_ = (c_ + c) & mask32
    d_ = (d_ + d) & mask32

  get -> ByteArray:
    digest := digest_
    if digest: return digest

    // The signature is 128 bits with the number of bits
    // in the content encoded in the last 64 of them.
    size := size_
    signature := ByteArray 16
    LITTLE_ENDIAN.put_int64 signature 8 (size * 8)

    // The padding starts with a 1 bit and then enough
    // zeros to make the total size a multiple of 64.
    padding := #[ 0x80 ]
    size += 1 + signature.size
    aligned := round_up size 64
    if aligned > size:
      padding += ByteArray (aligned - size)
      size = aligned

    // Add the padding and the signature.
    bytes := padding + signature
    add_bytes_ bytes
    assert: size_ == size

    digest = ByteArray 16
    LITTLE_ENDIAN.put_uint32 digest  0 a_
    LITTLE_ENDIAN.put_uint32 digest  4 b_
    LITTLE_ENDIAN.put_uint32 digest  8 c_
    LITTLE_ENDIAN.put_uint32 digest 12 d_
    digest_ = digest
    buffer_ = null
    return digest
