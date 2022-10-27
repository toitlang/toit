// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import binary show LITTLE_ENDIAN
import expect show *

import .checksum

/**
Cyclic Redundancy Check (CRC).

CRC is an error-detection code.

See https://en.wikipedia.org/wiki/Cyclic_redundancy_check
and https://crccalc.com/
*/

class Crc extends Checksum:
  width/int
  polynomial/int
  table_/List? := null
  little_endian/bool
  xor_result/int
  static cache_ := {:}

  sum_/int := ?

  hash_code -> int:
    return width ^ polynomial

  operator == other -> bool:
    if not other is Crc: return false
    return polynomial == other.polynomial
        and little_endian == other.little_endian
        and width == other.width

  /**
  Construct a CRC that processes bits in little-endian-first order.
  The $polynomial is an integer encoding of width $width with the most
    significant bit representing the x^0 term, and the least significant
    bit representing the x^width-1 term.  This is the little endian
    (reversed) ordering for the polynomial.

  # Example
  ```
  // The popular CRC-32 used in PNG.
  crc := Crc.little_endian 32 --polynomial=0xEDB88320 --initial_state=0xffff_ffff --xor_result=0xffff_ffff
  ```
  */
  constructor.little_endian .width/int --.polynomial/int --initial_state/int=0 --.xor_result/int=0:
    if polynomial > 1 << width: throw "Polynomial and width don't match"
    little_endian = true
    sum_=initial_state
    if cache_.contains this:
      table_ = cache_[this]
    else:
      table_ = calculate_table_little_endian_ width polynomial
      cache_[this] = table_

  /**
  Construct a CRC that processes bits in little-endian-first order.
  The $normal_polynomial is an integer encoding of width $width with the least
    significant bit representing the x^0 term, and the most significant bit
    representing the x^width-1 term.  This is the normal ordering for the
    polynomial.

  # Example
  ```
  // The popular CRC-32 used in PNG.
  crc := Crc.little_endian 32 --normal_polynomial=0x04C11DB7 --initial_state=0xffff_ffff --xor_result=0xffff_ffff
  ```
  */
  constructor.little_endian width/int --normal_polynomial/int --initial_state/int=0 --xor_result/int=0:
    polynomial := 0
    for i := 0; i < width; i++:
      if (normal_polynomial >> i) & 1 == 1:
        polynomial |= 1 << (width - 1 - i)
    return Crc.little_endian width --polynomial=polynomial --initial_state=initial_state --xor_result=xor_result

  /**
  Construct a CRC that processes bits in little-endian-first order.
  The $powers are a list of the powers in the representation of the
    CRC polynormial.
  The power corresponding to the width (32 for the x³² term in CRC-32)
    can be omitted since it is implied by the width of the CRC.

  # Example
  ```
  // The popular CRC-32 used in PNG.
  // x³² + x²⁶ + x²³ + x²² + x¹⁶ + x¹² + x¹¹ + x¹⁰ + x⁸ + x⁷ + x⁵ + x⁴ + x² + x + 1.
  crc := Crc.little_endian 32
      --powers=[26, 23, 22, 16, 12, 11, 10, 8, 7, 5, 4, 2, 1, 0]
      --initial_state=0xffff_ffff
      --xor_result=0xffff_ffff
  // Equivalently:
  crc := Crc.little_endian 32
      --powers=[32, 26, 23, 22, 16, 12, 11, 10, 8, 7, 5, 4, 2, 1, 0]
      --initial_state=0xffff_ffff
      --xor_result=0xffff_ffff
  ```
  */
  constructor.little_endian width/int --powers/List --initial_state/int=0 --xor_result/int=0:
    polynomial := 1 << (width - 1)
    powers.do:
      if 0 <= it < width:
        polynomial |= 1 << width - 1 - it
    return Crc.little_endian width --polynomial=polynomial --initial_state=initial_state --xor_result=xor_result

  /**
  Construct a CRC that processes bits in big-endian-first order.
  The $polynomial is an integer encoding of width $width with the most
    significant bit representing the x^0 term, and the least significant
    bit representing the x^width-1 term.

  # Example
  ```
  // The popular CRC-16 used in Xmodem.
  crc := Crc.big_endian 16 --polynomial=0x1021
  ```
  */
  constructor.big_endian .width/int --.polynomial/int --initial_state/int=0 --.xor_result/int=0:
    if polynomial > 1 << width: throw "Polynomial and width don't match"
    little_endian = false
    sum_ = initial_state
    if cache_.contains this:
      table_ = cache_[this]
    else:
      table_ = calculate_table_big_endian_ width polynomial
      cache_[this] = table_

  /**
  Construct a CRC that processes bits in big-endian-first order.
  The $powers are a list of the powers in the representation of the
    CRC polynormial.
  The power corresponding to the width (32 for the x³² term in CRC-32)
    can be omitted since it is implied by the width of the CRC.

  # Example
  ```
  // The popular CRC-16 used in Xmodem.
  crc := Crc.big_endian 16 --powers=[12, 5, 0]
  // Equivalently:
  crc := Crc.big_endian 16 --powers=[16, 12, 5, 0]
  ```
  */
  constructor.big_endian width/int --powers/List --initial_state/int=0 --xor_result/int=0:
    polynomial := 0
    powers.do:
      if 0 <= it < width:
        polynomial |= 1 << it
    return Crc.big_endian width --polynomial=polynomial --initial_state=initial_state --xor_result=xor_result

  calculate_table_little_endian_ width/int polynomial/int -> List:
    result := ?
    if width <= 8:
      result = ByteArray 256 --filler=0
    else:
      result = List 256: 0
    crc := 1
    for i := 128; i > 0 ; i >>= 1:
      if crc & 1 == 0:
        crc >>= 1
      else:
        crc = (crc >> 1) ^ polynomial
      for j := 0; j < 256; j += i + i:
        result[i + j] = crc ^ result[j]
    return result

  calculate_table_big_endian_ width/int polynomial/int -> List:
    result := ?
    if width <= 8:
      result = ByteArray 256 --filler=0
    else:
      result = List 256: 0
    hi_bit := 1 << (width - 1)
    mask := width == 64 ? -1 : ((1 << width) - 1)
    crc := hi_bit
    for i := 1; i < 256 ; i <<= 1:
      if crc & hi_bit == 0:
        crc <<= 1
      else:
        crc = (crc << 1) ^ polynomial
      crc &= mask
      i.repeat:
        result[i + it] = crc ^ result[it]
    return result

  /** See $super. */
  add data from/int to/int -> none:
    sum := sum_
    if little_endian:
      if data is string:
        (to - from).repeat:
          b := data.at --raw from + it
          sum = (sum >>> 8) ^ table_[(b ^ sum) & 0xff]
      else:
        if data is not ByteArray: throw "WRONG_OBJECT_TYPE"
        (to - from).repeat:
          b := data[from + it]
          sum = (sum >>> 8) ^ table_[(b ^ sum) & 0xff]
    else:
      // Big endian.
      mask := width == 64 ? -1 : ((1 << width) - 1)
      if data is string:
        (to - from).repeat:
          b := data.at --raw from + it
          sum = ((sum << 8) & mask) ^ table_[b ^ (sum >>> (width - 8))]
      else:
        if data is not ByteArray: throw "WRONG_OBJECT_TYPE"
        (to - from).repeat:
          b := data[from + it]
          sum = ((sum << 8) & mask) ^ table_[b ^ (sum >>> (width - 8))]
    sum_ = sum

  /**
  See $super.

  Returns the checksum as a width/4 element byte array in little-endian order.
  */
  get -> ByteArray:
    checksum := sum_ ^ xor_result
    return ByteArray (width + 7) / 8: (checksum >> (8 * it)) & 0xff
