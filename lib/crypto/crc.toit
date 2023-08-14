// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import binary
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
  table_ := null  // List or ByteArray or null.
  little-endian/bool
  xor-result/int
  static cache_ := {:}

  sum_/int := ?

  hash-code -> int:
    return width ^ polynomial

  operator == other -> bool:
    if not other is Crc: return false
    return polynomial == other.polynomial
        and little-endian == other.little-endian
        and width == other.width

  constructor.private_ other/Crc:
    width = other.width
    polynomial = other.polynomial
    table_ = other.table_
    little-endian = other.little-endian
    xor-result = other.xor-result
    sum_ = other.sum_

  clone -> Crc:
    return Crc.private_ this

  /**
  Construct a CRC that processes bits in little-endian-first order.
  The $polynomial is an integer encoding of width $width with the most
    significant bit representing the x^0 term, and the least significant
    bit representing the x^width-1 term.  This is the little endian
    (reversed) ordering for the polynomial.
  The $width must be in the range of 3-64 bits.

  # Example
  ```
  // The CRC-32 used in PNG.
  crc := Crc.little_endian 32 --polynomial=0xEDB88320 --initial_state=0xffff_ffff --xor_result=0xffff_ffff
  ```
  */
  constructor.little-endian .width/int --.polynomial/int --initial-state/int=0 --.xor-result/int=0:
    if not 3 <= width <= 64: throw "INVALID_ARGUMENT"
    if width < 64 and polynomial > (1 << width): throw "Polynomial and width don't match"
    little-endian = true
    sum_ = initial-state
    table_ = cache_.get this
        --init=: calculate-table-little-endian_ width polynomial

  /**
  Construct a CRC that processes bits in little-endian-first order.
  The $normal-polynomial is an integer encoding of width $width with the least
    significant bit representing the x^0 term, and the most significant bit
    representing the x^width-1 term.  This is the normal ordering for the
    polynomial.
  The $width must be in the range of 3-64 bits.

  # Example
  ```
  // The CRC-32 used in PNG.
  crc := Crc.little_endian 32 --normal_polynomial=0x04C11DB7 --initial_state=0xffff_ffff --xor_result=0xffff_ffff
  ```
  */
  constructor.little-endian .width/int --normal-polynomial/int --initial-state/int=0 --.xor-result/int=0:
    if not 3 <= width <= 64: throw "INVALID_ARGUMENT"
    poly := 0
    for i := 0; i < width; i++:
      if (normal-polynomial >> i) & 1 == 1:
        poly |= 1 << (width - 1 - i)
    if width < 64 and poly > (1 << width): throw "Polynomial and width don't match"
    polynomial = poly
    little-endian = true
    sum_ = initial-state
    table_ = cache_.get this
        --init=: calculate-table-little-endian_ width polynomial

  /**
  Construct a CRC that processes bits in little-endian-first order.
  The $powers are a list of the powers in the representation of the
    CRC polynormial.
  The power corresponding to the width (32 for the x³² term in CRC-32)
    can be omitted since it is implied by the width of the CRC.
  The $width must be in the range of 3-64 bits.

  # Example
  ```
  // The CRC-32 used in PNG.
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
  constructor.little-endian width/int --powers/List --initial-state/int=0 --xor-result/int=0:
    polynomial := 1 << (width - 1)
    powers.do:
      if 0 <= it < width:
        polynomial |= 1 << width - 1 - it
    return Crc.little-endian width --polynomial=polynomial --initial-state=initial-state --xor-result=xor-result

  /**
  Construct a CRC that processes bits in big-endian-first order.
  The $polynomial is an integer encoding of width $width with the most
    significant bit representing the x^0 term, and the least significant
    bit representing the x^width-1 term.
  The $width must be in the range of 8-64 bits.

  # Example
  ```
  // The CRC-16 used in Xmodem.
  crc := Crc.big_endian 16 --polynomial=0x1021
  ```
  */
  constructor.big-endian .width/int --.polynomial/int --initial-state/int=0 --.xor-result/int=0:
    if not 8 <= width <= 64: throw "INVALID_ARGUMENT"
    if width < 64 and polynomial > (1 << width): throw "Polynomial and width don't match"
    little-endian = false
    sum_ = initial-state
    table_ = cache_.get this
        --init=: calculate-table-big-endian_ width polynomial

  /**
  Construct a CRC that processes bits in big-endian-first order.
  The $powers are a list of the powers in the representation of the
    CRC polynormial.
  The power corresponding to the width (32 for the x³² term in CRC-32)
    can be omitted since it is implied by the width of the CRC.
  The $width must be in the range of 8-64 bits.

  # Example
  ```
  // The popular CRC-16 used in Xmodem.
  crc := Crc.big_endian 16 --powers=[12, 5, 0]
  // Equivalently:
  crc := Crc.big_endian 16 --powers=[16, 12, 5, 0]
  ```
  */
  constructor.big-endian width/int --powers/List --initial-state/int=0 --xor-result/int=0:
    polynomial := 0
    powers.do:
      if 0 <= it < width:
        polynomial |= 1 << it
    return Crc.big-endian width --polynomial=polynomial --initial-state=initial-state --xor-result=xor-result

  calculate-table-little-endian_ width/int polynomial/int -> any:
    result := ?
    if width <= 8:
      result = ByteArray 256 --filler=0
    else:
      result = List 256: 0
    crc := 1
    for i := 128; i > 0; i >>= 1:
      if crc & 1 == 0:
        crc >>>= 1
      else:
        crc = (crc >>> 1) ^ polynomial
      for j := 0; j < 256; j += i + i:
        result[i + j] = crc ^ result[j]
    return result

  calculate-table-big-endian_ width/int polynomial/int -> any:
    result := ?
    if width <= 8:
      result = ByteArray 256 --filler=0
    else:
      result = List 256: 0
    hi-bit := 1 << (width - 1)
    mask := width == 64 ? -1 : ((1 << width) - 1)
    crc := hi-bit
    for i := 1; i < 256; i <<= 1:
      if crc & hi-bit == 0:
        crc <<= 1
      else:
        crc = (crc << 1) ^ polynomial
      crc &= mask
      i.repeat:
        result[i + it] = crc ^ result[it]
    return result

  /** See $super. */
  add data from/int to/int -> none:
    if little-endian:
      sum_ = calculcate-crc-little-endian_ sum_ 0 data from to table_
    else:
      sum_ = calculcate-crc-big-endian_ sum_ width data from to table_

  // The zero argument should be zero to indicate to the primitive that
  // this is a little-endian CRC.
  static calculcate-crc-little-endian_ sum/int zero/int data from/int to/int table -> int:
    #primitive.core.crc:
      if data is string:
        (to - from).repeat:
          b := data.at --raw from + it
          sum = (sum >>> 8) ^ table[(b ^ sum) & 0xff]
      else:
        if data is not ByteArray: throw "WRONG_OBJECT_TYPE"
        (to - from).repeat:
          b := data[from + it]
          sum = (sum >>> 8) ^ table[(b ^ sum) & 0xff]
      return sum

  static calculcate-crc-big-endian_ sum/int width/int data from/int to/int table -> int:
    #primitive.core.crc:
      mask := width == 64 ? -1 : ((1 << width) - 1)
      if data is string:
        (to - from).repeat:
          b := data.at --raw from + it
          sum = ((sum << 8) & mask) ^ table[b ^ (sum >>> (width - 8))]
      else:
        if data is not ByteArray: throw "WRONG_OBJECT_TYPE"
        (to - from).repeat:
          b := data[from + it]
          sum = ((sum << 8) & mask) ^ table[b ^ (sum >>> (width - 8))]
      return sum

  /**
  See $super.

  Returns the checksum as a width/4 element byte array in the endian order that
    corresponds to the constructor used.
  */
  get -> ByteArray:
    checksum := sum_ ^ xor-result
    result := ByteArray (width + 7) >> 3
    if little-endian:
      binary.LITTLE-ENDIAN.put-uint result result.size 0 checksum
    else:
      binary.BIG-ENDIAN.put-uint result result.size 0 checksum
    return result

  /**
  Returns the checksum as an integer.
  */
  get-as-int -> int:
    if width == 64:
      return sum_ ^ xor-result
    return (sum_ ^ xor-result) & ((1 << width) - 1)

/**
Computes the CRC-16/CCITT-FALSE checksum of the given $data.

The $data must be a string or byte array.
Returns the checksum as a 16-bit integer.
*/
crc16-ccitt-false data -> int:
  crc := Crc.big-endian 16 --polynomial=0x1021 --initial-state=0xffff
  crc.add data
  return crc.get-as-int

/** CRC-16/CCITT-FALSE checksum state. */
class Crc16CcittFalse extends Crc:
  constructor:
    super.big-endian 16 --polynomial=0x1021 --initial-state=0xffff

/**
Computes the CRC-16/ARC checksum of the given $data.

The $data must be a string or byte array.
Returns the checksum as a 16-bit integer.
*/
crc16-arc data -> int:
  crc := Crc.little-endian 16 --normal-polynomial=0x8005
  crc.add data
  return crc.get-as-int

/** CRC-16/ARC checksum state. */
class Crc16Arc extends Crc:
  constructor:
    super.little-endian 16 --normal-polynomial=0x8005

/**
Computes the CRC-16/AUG-CCITT checksum of the given $data.

The $data must be a string or byte array.
Returns the checksum as a 16-bit integer.
*/
crc16-aug-ccitt data -> int:
  crc := Crc.big-endian 16 --polynomial=0x1021 --initial-state=0x1d0f
  crc.add data
  return crc.get-as-int

/** CRC-16/AUG-CCITT checksum state. */
class Crc16AugCcitt extends Crc:
  constructor:
    super.big-endian 16 --polynomial=0x1021 --initial-state=0x1d0f

/**
Computes the CRC-16/BUYPASS checksum of the given $data.

The $data must be a string or byte array.
Returns the checksum as a 16-bit integer.
*/
crc16-buypass data -> int:
  crc := Crc.big-endian 16 --polynomial=0x8005
  crc.add data
  return crc.get-as-int

/** CRC-16/BUYPASS checksum state. */
class Crc16Buypass extends Crc:
  constructor:
    super.big-endian 16 --polynomial=0x8005

/**
Computes the CRC-16/CDMA2000 checksum of the given $data.

The $data must be a string or byte array.
Returns the checksum as a 16-bit integer.
*/
crc16-cdma2000 data -> int:
  crc := Crc.big-endian 16 --polynomial=0xC867 --initial-state=0xffff
  crc.add data
  return crc.get-as-int

/** CRC-16/CDMA2000 checksum state. */
class Crc16Cdma2000 extends Crc:
  constructor:
    super.big-endian 16 --polynomial=0xC867 --initial-state=0xffff

/**
Computes the CRC-16/DDS-110 checksum of the given $data.

The $data must be a string or byte array.
Returns the checksum as a 16-bit integer.
*/
crc16-dds110 data -> int:
  crc := Crc.big-endian 16 --polynomial=0x8005 --initial-state=0x800d
  crc.add data
  return crc.get-as-int

/** CRC-16/DDS-110 checksum state. */
class Crc16Dds110 extends Crc:
  constructor:
    super.big-endian 16 --polynomial=0x8005 --initial-state=0x800d

/**
Computes the CRC-16/DECT-R checksum of the given $data.

The $data must be a string or byte array.
Returns the checksum as a 16-bit integer.
*/
crc16-dect-r data -> int:
  crc := Crc.big-endian 16 --polynomial=0x0589 --xor-result=0x1
  crc.add data
  return crc.get-as-int

/** CRC-16/DECT-R checksum state. */
class Crc16DectR extends Crc:
  constructor:
    super.big-endian 16 --polynomial=0x0589 --xor-result=0x1

/**
Computes the CRC-16/DECT-X checksum of the given $data.

The $data must be a string or byte array.
Returns the checksum as a 16-bit integer.
*/
crc16-dect-x data -> int:
  crc := Crc.big-endian 16 --polynomial=0x0589
  crc.add data
  return crc.get-as-int

/** CRC-16/DECT-X checksum state. */
class Crc16DectX extends Crc:
  constructor:
    super.big-endian 16 --polynomial=0x0589

/**
Computes the CRC-16/DNP checksum of the given $data.

The $data must be a string or byte array.
Returns the checksum as a 16-bit integer.
*/
crc16-dnp data -> int:
  crc := Crc.little-endian 16 --normal-polynomial=0x3D65 --xor-result=0xffff
  crc.add data
  return crc.get-as-int

/** CRC-16/DNP checksum state. */
class Crc16Dnp extends Crc:
  constructor:
    super.little-endian 16 --normal-polynomial=0x3D65 --xor-result=0xffff

/**
Computes the CRC-16/EN-13757 checksum of the given $data.

The $data must be a string or byte array.
Returns the checksum as a 16-bit integer.
*/
crc16-en13757 data -> int:
  crc := Crc.big-endian 16 --polynomial=0x3D65 --xor-result=0xffff
  crc.add data
  return crc.get-as-int

/** CRC-16/EN-13757 checksum state. */
class Crc16En13757 extends Crc:
  constructor:
    super.big-endian 16 --polynomial=0x3D65 --xor-result=0xffff

/**
Computes the CRC-16/GENIBUS checksum of the given $data.

The $data must be a string or byte array.
Returns the checksum as a 16-bit integer.
*/
crc16-genibus data -> int:
  crc := Crc.big-endian 16 --polynomial=0x1021 --initial-state=0xffff --xor-result=0xffff
  crc.add data
  return crc.get-as-int

/** CRC-16/GENIBUS checksum state. */
class Crc16Genibus extends Crc:
  constructor:
    super.big-endian 16 --polynomial=0x1021 --initial-state=0xffff --xor-result=0xffff

/**
Computes the CRC-16/MAXIM checksum of the given $data.

The $data must be a string or byte array.
Returns the checksum as a 16-bit integer.
*/
crc16-maxim data -> int:
  crc := Crc.little-endian 16 --normal-polynomial=0x8005 --xor-result=0xffff
  crc.add data
  return crc.get-as-int

/** CRC-16/MAXIM checksum state. */
class Crc16Maxim extends Crc:
  constructor:
    super.little-endian 16 --normal-polynomial=0x8005 --xor-result=0xffff

/**
Computes the CRC-16/MCRF4XX checksum of the given $data.

The $data must be a string or byte array.
Returns the checksum as a 16-bit integer.
*/
crc16-mcrf4xx data -> int:
  crc := Crc.little-endian 16 --normal-polynomial=0x1021 --initial-state=0xffff
  crc.add data
  return crc.get-as-int

/** CRC-16/MCRF4XX checksum state. */
class Crc16Mcrf4xx extends Crc:
  constructor:
    super.little-endian 16 --normal-polynomial=0x1021 --initial-state=0xffff

/**
Computes the CRC-16/RIELLO checksum of the given $data.

The $data must be a string or byte array.
Returns the checksum as a 16-bit integer.

# Note
Crccalc.com lists the initial state of the CRC as 0xB2AA, whereas we
  use the initial value of 0x554D, the bit reversed value.  This value is the
  one that gives the correct result (matching crccalc.com's check) when run
  with our code, and it is also the value given in the specification at
  https://networkupstools.org/protocols/riello/PSGPSER-0104.pdf
*/
crc16-riello data -> int:
  crc := Crc.little-endian 16 --normal-polynomial=0x1021 --initial-state=0x554d
  crc.add data
  return crc.get-as-int

/**
CRC-16/RIELLO checksum state.

# Note
Crccalc.com lists the initial state of the CRC as 0xB2AA, whereas we
  use the initial value of 0x554D, the bit reversed value.  This value is the
  one that gives the correct result (matching crccalc.com's check) when run
  with our code, and it is also the value given in the specification at
  https://networkupstools.org/protocols/riello/PSGPSER-0104.pdf
*/
class Crc16Riello extends Crc:
  constructor:
    super.little-endian 16 --normal-polynomial=0x1021 --initial-state=0x554d

/**
Computes the CRC-16/T10-DIF checksum of the given $data.

The $data must be a string or byte array.
Returns the checksum as a 16-bit integer.
*/
crc16-t10-dif data -> int:
  crc := Crc.big-endian 16 --polynomial=0x8BB7
  crc.add data
  return crc.get-as-int

/** CRC-16/T10-DIF checksum state. */
class Crc16T10Dif extends Crc:
  constructor:
    super.big-endian 16 --polynomial=0x8BB7

/**
Computes the CRC-16/TELEDISK checksum of the given $data.

The $data must be a string or byte array.
Returns the checksum as a 16-bit integer.
*/
crc16-teledisk data -> int:
  crc := Crc.big-endian 16 --polynomial=0xA097
  crc.add data
  return crc.get-as-int

/** CRC-16/TELEDISK checksum state. */
class Crc16Teledisk extends Crc:
  constructor:
    super.big-endian 16 --polynomial=0xA097

/**
Computes the CRC-16/TMS37157 checksum of the given $data.

The $data must be a string or byte array.
Returns the checksum as a 16-bit integer.

# Note
Crccalc.com lists the initial state of the CRC as 0x89EC, whereas we
  use the initial value of 0x3791, the bit reversed value.  This value is the
  one that gives the correct result (matching crccalc.com's check) when run
  with our code.
*/
crc16-tms37157 data -> int:
  crc := Crc.little-endian 16 --normal-polynomial=0x1021 --initial-state=0x3791
  crc.add data
  return crc.get-as-int

/**
CRC-16/TMS37157 checksum state.

# Note
Crccalc.com lists the initial state of the CRC as 0x89EC, whereas we
  use the initial value of 0x3791, the bit reversed value.  This value is the
  one that gives the correct result (matching crccalc.com's check) when run
  with our code.
*/
class Crc16Tms37157 extends Crc:
  constructor:
    super.little-endian 16 --normal-polynomial=0x1021 --initial-state=0x3791

/**
Computes the CRC-16/USB checksum of the given $data.

The $data must be a string or byte array.
Returns the checksum as a 16-bit integer.
*/
crc16-usb data -> int:
  crc := Crc.little-endian 16 --normal-polynomial=0x8005 --initial-state=0xffff --xor-result=0xffff
  crc.add data
  return crc.get-as-int

/** CRC-16/USB checksum state. */
class Crc16Usb extends Crc:
  constructor:
    super.little-endian 16 --normal-polynomial=0x8005 --initial-state=0xffff --xor-result=0xffff

/**
Computes the CRC-A checksum of the given $data.

The $data must be a string or byte array.
Returns the checksum as a 16-bit integer.

# Note
Crccalc.com lists the initial state of the CRC as 0xC6C6, whereas we
  use the initial value of 0x6363, the bit reversed value.  This value is the
  one that gives the correct result (matching crccalc.com's check) when run
  with our code.
*/
crc-a data -> int:
  crc := Crc.little-endian 16 --normal-polynomial=0x1021 --initial-state=0x6363
  crc.add data
  return crc.get-as-int

/**
CRC-A checksum state.

# Note
Crccalc.com lists the initial state of the CRC as 0xC6C6, whereas we
  use the initial value of 0x6363, the bit reversed value.  This value is the
  one that gives the correct result (matching crccalc.com's check) when run
  with our code.
*/
class CrcA extends Crc:
  constructor:
    super.little-endian 16 --normal-polynomial=0x1021 --initial-state=0x6363

/**
Computes the CRC-16/KERMIT checksum of the given $data.

The $data must be a string or byte array.
Returns the checksum as a 16-bit integer.
*/
crc16-kermit data -> int:
  crc := Crc.little-endian 16 --normal-polynomial=0x1021
  crc.add data
  return crc.get-as-int

/** CRC-16/KERMIT checksum state. */
class Crc16Kermit extends Crc:
  constructor:
    super.little-endian 16 --normal-polynomial=0x1021

/**
Computes the CRC-16/MODBUS checksum of the given $data.

The $data must be a string or byte array.
Returns the checksum as a 16-bit integer.
*/
crc16-modbus data -> int:
  crc := Crc.little-endian 16 --normal-polynomial=0x8005 --initial-state=0xffff
  crc.add data
  return crc.get-as-int

/** CRC-16/MODBUS checksum state. */
class Crc16Modbus extends Crc:
  constructor:
    super.little-endian 16 --normal-polynomial=0x8005 --initial-state=0xffff

/**
Computes the CRC-16/X-25 checksum of the given $data.

The $data must be a string or byte array.
Returns the checksum as a 16-bit integer.
*/
crc16-x25 data -> int:
  crc := Crc.little-endian 16 --normal-polynomial=0x1021 --initial-state=0xffff --xor-result=0xffff
  crc.add data
  return crc.get-as-int

/** CRC-16/X-25 checksum state. */
class Crc16X25 extends Crc:
  constructor:
    super.little-endian 16 --normal-polynomial=0x1021 --initial-state=0xffff --xor-result=0xffff

/**
Computes the CRC-16/XMODEM checksum of the given $data.

The $data must be a string or byte array.
Returns the checksum as a 16-bit integer.
*/
crc16-xmodem data -> int:
  crc := Crc.big-endian 16 --polynomial=0x1021
  crc.add data
  return crc.get-as-int

/** CRC-16/XMODEM checksum state. */
class Crc16Xmodem extends Crc:
  constructor:
    super.big-endian 16 --polynomial=0x1021

/**
Computes the CRC-8 checksum of the given $data.

The $data must be a string or byte array.
Returns the checksum as an 8-bit integer.
*/
crc8 data -> int:
  crc := Crc.big-endian 8 --polynomial=0x07
  crc.add data
  return crc.get-as-int

/** CRC-8 checksum state. */
class Crc8 extends Crc:
  constructor:
    super.big-endian 8 --polynomial=0x07

/**
Computes the CRC-8/CDMA2000 checksum of the given $data.

The $data must be a string or byte array.
Returns the checksum as an 8-bit integer.
*/
crc8-cdma2000 data -> int:
  crc := Crc.big-endian 8 --polynomial=0x9B --initial-state=0xff
  crc.add data
  return crc.get-as-int

/** CRC-8/CDMA2000 checksum state. */
class Crc8Cdma2000 extends Crc:
  constructor:
    super.big-endian 8 --polynomial=0x9B --initial-state=0xff

/**
Computes the CRC-8/DARC checksum of the given $data.

The $data must be a string or byte array.
Returns the checksum as an 8-bit integer.
*/
crc8-darc data -> int:
  crc := Crc.little-endian 8 --normal-polynomial=0x39
  crc.add data
  return crc.get-as-int

/** CRC-8/DARC checksum state. */
class Crc8Darc extends Crc:
  constructor:
    super.little-endian 8 --normal-polynomial=0x39

/**
Computes the CRC-8/DVB-S2 checksum of the given $data.

The $data must be a string or byte array.
Returns the checksum as an 8-bit integer.
*/
crc8-dvb-s2 data -> int:
  crc := Crc.big-endian 8 --polynomial=0xD5
  crc.add data
  return crc.get-as-int

/** CRC-8/DVB-S2 checksum state. */
class Crc8DvbS2 extends Crc:
  constructor:
    super.big-endian 8 --polynomial=0xD5

/**
Computes the CRC-8/EBU checksum of the given $data.

The $data must be a string or byte array.
Returns the checksum as an 8-bit integer.
*/
crc8-ebu data -> int:
  crc := Crc.little-endian 8 --normal-polynomial=0x1D --initial-state=0xff
  crc.add data
  return crc.get-as-int

/** CRC-8/EBU checksum state. */
class Crc8Ebu extends Crc:
  constructor:
    super.little-endian 8 --normal-polynomial=0x1D --initial-state=0xff

/**
Computes the CRC-8/I-CODE checksum of the given $data.

The $data must be a string or byte array.
Returns the checksum as an 8-bit integer.
*/
crc8-i-code data -> int:
  crc := Crc.big-endian 8 --polynomial=0x1D --initial-state=0xfd
  crc.add data
  return crc.get-as-int

/** CRC-8/I-CODE checksum state. */
class Crc8ICode extends Crc:
  constructor:
    super.big-endian 8 --polynomial=0x1D --initial-state=0xfd

/**
Computes the CRC-8/ITU checksum of the given $data.

The $data must be a string or byte array.
Returns the checksum as an 8-bit integer.
*/
crc8-itu data -> int:
  crc := Crc.big-endian 8 --polynomial=0x07 --xor-result=0x55
  crc.add data
  return crc.get-as-int

/** CRC-8/ITU checksum state. */
class Crc8Itu extends Crc:
  constructor:
    super.big-endian 8 --polynomial=0x07 --xor-result=0x55

/**
Computes the CRC-8/MAXIM checksum of the given $data.

The $data must be a string or byte array.
Returns the checksum as an 8-bit integer.
*/
crc8-maxim data -> int:
  crc := Crc.little-endian 8 --normal-polynomial=0x31
  crc.add data
  return crc.get-as-int

/** CRC-8/MAXIM checksum state. */
class Crc8Maxim extends Crc:
  constructor:
    super.little-endian 8 --normal-polynomial=0x31

/**
Computes the CRC-8/ROHC checksum of the given $data.

The $data must be a string or byte array.
Returns the checksum as an 8-bit integer.
*/
crc8-rohc data -> int:
  crc := Crc.little-endian 8 --normal-polynomial=0x07 --initial-state=0xff
  crc.add data
  return crc.get-as-int

/** CRC-8/ROHC checksum state. */
class Crc8Rohc extends Crc:
  constructor:
    super.little-endian 8 --normal-polynomial=0x07 --initial-state=0xff

/**
Computes the CRC-8/WCDMA checksum of the given $data.

The $data must be a string or byte array.
Returns the checksum as an 8-bit integer.
*/
crc8-wcdma data -> int:
  crc := Crc.little-endian 8 --normal-polynomial=0x9B
  crc.add data
  return crc.get-as-int

/** CRC-8/WCDMA checksum state. */
class Crc8Wcdma extends Crc:
  constructor:
    super.little-endian 8 --normal-polynomial=0x9B

/**
Computes the CRC-32 checksum of the given $data.

The $data must be a string or byte array.
Returns the checksum as a 32-bit integer.
*/
crc32 data -> int:
  crc := Crc.little-endian 32 --normal-polynomial=0x04C11DB7 --initial-state=0xffffffff --xor-result=0xffffffff
  crc.add data
  return crc.get-as-int

/** CRC-32 checksum state. */
class Crc32 extends Crc:
  constructor:
    super.little-endian 32 --normal-polynomial=0x04C11DB7 --initial-state=0xffffffff --xor-result=0xffffffff

/**
Computes the CRC-32/BZIP2 checksum of the given $data.

The $data must be a string or byte array.
Returns the checksum as a 32-bit integer.
*/
crc32-bzip2 data -> int:
  crc := Crc.big-endian 32 --polynomial=0x04C11DB7 --initial-state=0xffffffff --xor-result=0xffffffff
  crc.add data
  return crc.get-as-int

/** CRC-32/BZIP2 checksum state. */
class Crc32Bzip2 extends Crc:
  constructor:
    super.big-endian 32 --polynomial=0x04C11DB7 --initial-state=0xffffffff --xor-result=0xffffffff

/**
Computes the CRC-32C checksum of the given $data.

The $data must be a string or byte array.
Returns the checksum as a 32-bit integer.
*/
crc32c data -> int:
  crc := Crc.little-endian 32 --normal-polynomial=0x1EDC6F41 --initial-state=0xffffffff --xor-result=0xffffffff
  crc.add data
  return crc.get-as-int

/** CRC-32C checksum state. */
class Crc32c extends Crc:
  constructor:
    super.little-endian 32 --normal-polynomial=0x1EDC6F41 --initial-state=0xffffffff --xor-result=0xffffffff

/**
Computes the CRC-32D checksum of the given $data.

The $data must be a string or byte array.
Returns the checksum as a 32-bit integer.
*/
crc32d data -> int:
  crc := Crc.little-endian 32 --normal-polynomial=0xA833982B --initial-state=0xffffffff --xor-result=0xffffffff
  crc.add data
  return crc.get-as-int

/** CRC-32D checksum state. */
class Crc32d extends Crc:
  constructor:
    super.little-endian 32 --normal-polynomial=0xA833982B --initial-state=0xffffffff --xor-result=0xffffffff

/**
Computes the CRC-32/JAMCRC checksum of the given $data.

The $data must be a string or byte array.
Returns the checksum as a 32-bit integer.
*/
crc32-jamcrc data -> int:
  crc := Crc.little-endian 32 --normal-polynomial=0x04C11DB7 --initial-state=0xffffffff
  crc.add data
  return crc.get-as-int

/** CRC-32/JAMCRC checksum state. */
class Crc32Jamcrc extends Crc:
  constructor:
    super.little-endian 32 --normal-polynomial=0x04C11DB7 --initial-state=0xffffffff

/**
Computes the CRC-32/MPEG-2 checksum of the given $data.

The $data must be a string or byte array.
Returns the checksum as a 32-bit integer.
*/
crc32-mpeg2 data -> int:
  crc := Crc.big-endian 32 --polynomial=0x04C11DB7 --initial-state=0xffffffff
  crc.add data
  return crc.get-as-int

/** CRC-32/MPEG-2 checksum state. */
class Crc32Mpeg2 extends Crc:
  constructor:
    super.big-endian 32 --polynomial=0x04C11DB7 --initial-state=0xffffffff

/**
Computes the CRC-32/POSIX checksum of the given $data.

The $data must be a string or byte array.
Returns the checksum as a 32-bit integer.
*/
crc32-posix data -> int:
  crc := Crc.big-endian 32 --polynomial=0x04C11DB7 --xor-result=0xffffffff
  crc.add data
  return crc.get-as-int

/** CRC-32/POSIX checksum state. */
class Crc32Posix extends Crc:
  constructor:
    super.big-endian 32 --polynomial=0x04C11DB7 --xor-result=0xffffffff

/**
Computes the CRC-32Q checksum of the given $data.

The $data must be a string or byte array.
Returns the checksum as a 32-bit integer.
*/
crc32q data -> int:
  crc := Crc.big-endian 32 --polynomial=0x814141AB
  crc.add data
  return crc.get-as-int

/** CRC-32Q checksum state. */
class Crc32q extends Crc:
  constructor:
    super.big-endian 32 --polynomial=0x814141AB

/**
Computes the CRC-32/XFER checksum of the given $data.

The $data must be a string or byte array.
Returns the checksum as a 32-bit integer.
*/
crc32-xfer data -> int:
  crc := Crc.big-endian 32 --polynomial=0x000000AF
  crc.add data
  return crc.get-as-int

/** CRC-32/XFER checksum state. */
class Crc32Xfer extends Crc:
  constructor:
    super.big-endian 32 --polynomial=0x000000AF

/**
Computes the CRC-64/XZ checksum of the given $data.

The $data must be a string or byte array.
Returns the checksum as a 32-bit integer.
*/
crc64-xz data -> int:
  crc := Crc.little-endian 64 --normal-polynomial=0x42f0e1eba9ea3693 --initial-state=-1 --xor-result=-1
  crc.add data
  return crc.get-as-int

/** CRC-64/XZ checksum state. */
class Crc64Xz extends Crc:
  constructor:
    super.little-endian 64 --normal-polynomial=0x42f0e1eba9ea3693 --initial-state=-1 --xor-result=-1
