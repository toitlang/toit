// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .checksum
import io
import io show LITTLE-ENDIAN

/**
Pure Toit MD5 implementation.
*/
class Md5 extends Checksum:
  // Strings are slightly faster than byte arrays.
  static SHIFTS_ ::= "\x07\x0c\x11\x16\x07\x0c\x11\x16\x07\x0c\x11\x16\x07\x0c\x11\x16\x05\x09\x0e\x14\x05\x09\x0e\x14\x05\x09\x0e\x14\x05\x09\x0e\x14\x04\x0b\x10\x17\x04\x0b\x10\x17\x04\x0b\x10\x17\x04\x0b\x10\x17\x06\x0a\x0f\x15\x06\x0a\x0f\x15\x06\x0a\x0f\x15\x06\x0a\x0f\x15"

  static F_ ::= "\x00\x04\x08\x0c\x10\x14\x18\x1c\x20\x24\x28\x2c\x30\x34\x38\x3c\x04\x18\x2c\x00\x14\x28\x3c\x10\x24\x38\x0c\x20\x34\x08\x1c\x30\x14\x20\x2c\x38\x04\x10\x1c\x28\x34\x00\x0c\x18\x24\x30\x3c\x08\x00\x1c\x38\x14\x30\x0c\x28\x04\x20\x3c\x18\x34\x10\x2c\x08\x24"

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

  static BLOCK-SIZE ::= 64

  size_/int := 0
  buffer_/ByteArray? := ByteArray BLOCK-SIZE

  a_/int := 0x67452301
  b_/int := 0xefcdab89
  c_/int := 0x98badcfe
  d_/int := 0x10325476

  clone -> Md5:
    return Md5.private_ size_ buffer_ a_ b_ c_ d_

  constructor:

  constructor.private_ .size_ buffer/ByteArray? .a_ .b_ .c_ .d_:
    buffer_ = buffer.copy

  add data/io.Data from/int to/int -> none:
    if not buffer_: throw "ALREADY_CLOSED"
    slice := ?
    if data is ByteArray:
      slice = (data as ByteArray)[from..to]
    else:
      slice = ByteArray.from data from to
    add-bytes_ slice

  add-bytes_ bytes/ByteArray -> none:
    extra := bytes.size
    fullness := size_ & 0x3f
    size_ += extra

    // See if we can fit all the extra bytes into the buffer.
    buffer := buffer_
    n := BLOCK-SIZE - fullness
    if extra < n:
      buffer.replace fullness bytes
      return

    // We have enough extra bytes to fill up the
    // buffer completely.
    buffer.replace fullness bytes 0 n
    add-chunk_ buffer 0

    // Run through the extra bytes and add the
    // full chunks we can find without copying
    // the bytes into the buffer.
    while true:
      next := n + BLOCK-SIZE
      if next > extra:
        // Save the last extra bytes in the buffer,
        // so we have them for the next add.
        buffer.replace 0 bytes n
        return
      add-chunk_ bytes n
      n = next

  // Takes the 64 bytes, starting at $from.
  add-chunk_ chunk/ByteArray from/int -> none:
    noise := NOISE_
    shifts := SHIFTS_
    f := F_
    mask32 := 0xffff_ffff

    a := a_
    b := b_
    c := c_
    d := d_

    BLOCK-SIZE.repeat: | i/int |
      e := ?
      if i < 32:
        if i < 16:
          e = (b & c) | (~b & d)
        else:
          e = (d & b) | (~d & c)
      else:
        if i < 48:
          e = b ^ c ^ d
        else:
          e = c ^ (b | (~d & mask32))

      t := d
      d = c
      c = b
      ae := a + e
      cf := LITTLE-ENDIAN.uint32 chunk (from + f[i])
      nc := noise[i] + cf
      aenc := (ae + nc) & mask32
      shift := shifts[i]
      rotated := (aenc << shift) | (aenc >> (32 - shift))
      b = (b + rotated) & mask32
      a = t

    a_ = (a_ + a) & mask32
    b_ = (b_ + b) & mask32
    c_ = (c_ + c) & mask32
    d_ = (d_ + d) & mask32

  get -> ByteArray:
    if buffer_ == null: throw "ALREADY_CLOSED"

    // The signature is 64 bits with the number of bits
    // in the content encoded in them.
    size := size_
    signature := ByteArray 8
    LITTLE-ENDIAN.put-int64 signature 0 (size * 8)

    // The padding starts with a 1 bit and then enough
    // zeros to make the total size a multiple of 64.
    padding := #[ 0x80 ]
    size += 1 + signature.size
    aligned := round-up size 64
    if aligned > size:
      padding += ByteArray (aligned - size)
      size = aligned

    // Add the padding and the signature.
    bytes := padding + signature
    add-bytes_ bytes
    assert: size_ == size

    digest := ByteArray 16
    LITTLE-ENDIAN.put-uint32 digest  0 a_
    LITTLE-ENDIAN.put-uint32 digest  4 b_
    LITTLE-ENDIAN.put-uint32 digest  8 c_
    LITTLE-ENDIAN.put-uint32 digest 12 d_
    buffer_ = null
    return digest

/**
Computes the MD5 hash of the given $data.
*/
md5 data/io.Data from/int=0 to/int=data.byte-size -> ByteArray:
  return checksum Md5 data from to
