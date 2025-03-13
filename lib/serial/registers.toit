// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import io show LITTLE-ENDIAN BIG-ENDIAN

/**
Common integer operations for device registers.
*/

/**
Support for reading and writing integers to device registers.
Supports:
- 8-, 16-, 24-, and 32-bit integers
- Signed and unsigned integers
- Little endian and big endian
*/
abstract class Registers:
  /**
  Reads the $count bytes from the given $register.

  Returns a byte array of the read bytes.
  */
  abstract read-bytes register/int count/int -> ByteArray
  /**
  Variant of $(read-bytes register count)

  Calls the $failure block in case of an exception.

  Deprecated. Use exception handling instead.
  */
  abstract read-bytes register/int count/int [failure] -> ByteArray
  /** Writes the $data to the given $register. */
  abstract write-bytes register/int data/ByteArray -> none

  buffer-1_/ByteArray? := null
  buffer-2_/ByteArray? := null
  buffer-3_/ByteArray? := null
  buffer-4_/ByteArray? := null

  /** Reads an unsigned 8-bit integer from the $register. */
  read-u8 register/int -> int:
    bytes := read-bytes register 1
    return bytes[0]

  /** Reads a signed 8-bit integer from the $register. */
  read-i8 register/int -> int:
    v := read-u8 register
    if v >= 128: return v - 256
    return v

  /**
  Reads a signed 16-bit integer from the $register.

  Uses little endian.
  */
  read-i16-le register/int -> int:
    bytes := read-bytes register 2
    return LITTLE-ENDIAN.int16 bytes 0

  /**
  Reads a signed 16-bit integer from the $register.

  Uses big endian.
  */
  read-i16-be register/int -> int:
    bytes := read-bytes register 2
    return BIG-ENDIAN.int16 bytes 0

  /**
  Reads an unsigned 16-bit integer from the $register.

  Uses little endian.
  */
  read-u16-le register/int -> int:
    bytes := read-bytes register 2
    return LITTLE-ENDIAN.uint16 bytes 0

  /**
  Reads an unsigned 16-bit integer from the $register.

  Uses big endian.
  */
  read-u16-be register/int -> int:
    bytes := read-bytes register 2
    return BIG-ENDIAN.uint16 bytes 0

  /**
  Reads an unsigned 16-bit integer from the $register.

  Uses little endian.

  Calls the $failure block in case of an exception.

  Deprecated. Use exception handling instead.
  */
  read-u16-be register/int [failure] -> int:
    e := catch:
      bytes := read-bytes register 2
      return BIG-ENDIAN.uint16 bytes 0
    return failure.call e


  /**
  Reads a signed 24-bit integer from the $register.

  Uses little endian.
  */
  read-i24-le register/int -> int:
    bytes := read-bytes register 3
    return LITTLE-ENDIAN.int24 bytes 0

  /**
  Reads a signed 24-bit integer from the $register.

  Uses big endian.
  */
  read-i24-be register/int -> int:
    bytes := read-bytes register 3
    return BIG-ENDIAN.int24 bytes 0

  /**
  Reads an unsigned 24-bit integer from the $register.

  Uses little endian.
  */
  read-u24-le register/int -> int:
    bytes := read-bytes register 3
    return LITTLE-ENDIAN.uint24 bytes 0

  /**
  Reads an unsigned 24-bit integer from the $register.

  Uses big endian.
  */
  read-u24-be register/int -> int:
    bytes := read-bytes register 3
    return BIG-ENDIAN.uint24 bytes 0

  /**
  Reads a signed 32-bit integer from the $register.

  Uses little endian.
  */
  read-i32-le register/int -> int:
    bytes := read-bytes register 4
    return LITTLE-ENDIAN.int32 bytes 0

  /**
  Reads a signed 32-bit integer from the $register.

  Uses big endian.
  */
  read-i32-be register/int -> int:
    bytes := read-bytes register 4
    return BIG-ENDIAN.int32 bytes 0

  /**
  Reads an unsigned 32-bit integer from the $register.

  Uses little endian.
  */
  read-u32-le register/int -> int:
    bytes := read-bytes register 4
    return LITTLE-ENDIAN.uint32 bytes 0

  /**
  Reads an unsigned 32-bit integer from the $register.

  Uses big endian.
  */
  read-u32-be register/int -> int:
    bytes := read-bytes register 4
    return BIG-ENDIAN.uint32 bytes 0

  /**
  Writes the $value to the given $register as an unsigned 8-bit integer.
  */
  write-u8 register/int value/int -> none:
    if not buffer-1_: buffer-1_ = ByteArray 1
    buffer-1_[0] = value
    write-bytes register buffer-1_

  /** Writes the $value to the given $register as a signed 8-bit integer. */
  write-i8 register/int value/int -> none:
    if not -128 <= value <= 127: throw "OUT_OF_BOUNDS"
    if not buffer-1_: buffer-1_ = ByteArray 1
    buffer-1_[0] = value
    write-bytes register buffer-1_

  /**
  Writes the $value to the given $register as an unsigned 16-bit integer.

  Uses little endian.
  */
  write-u16-le register/int value/int -> none:
    if not buffer-2_: buffer-2_ = ByteArray 2
    LITTLE-ENDIAN.put-uint16 buffer-2_ 0 value
    write-bytes register buffer-2_

  /**
  Writes the $value to the given $register as a signed 16-bit integer.

  Uses little endian.
  */
  write-i16-le register/int value/int -> none:
    if not buffer-2_: buffer-2_ = ByteArray 2
    LITTLE-ENDIAN.put-int16 buffer-2_ 0 value
    write-bytes register buffer-2_

  /**
  Writes the $value to the given $register as an unsigned 16-bit integer.

  Uses big endian.
  */
  write-u16-be register/int value/int -> none:
    if not buffer-2_: buffer-2_ = ByteArray 2
    BIG-ENDIAN.put-uint16 buffer-2_ 0 value
    write-bytes register buffer-2_

  /**
  Writes the $value to the given $register as a signed 16-bit integer.

  Uses big endian.
  */
  write-i16-be register/int value/int -> none:
    if not buffer-2_: buffer-2_ = ByteArray 2
    BIG-ENDIAN.put-int16 buffer-2_ 0 value
    write-bytes register buffer-2_

  /**
  Writes the $value to the given $register as an unsigned 24-bit integer.

  Uses little endian.
  */
  write-u24-le register/int value/int -> none:
    if not buffer-3_: buffer-3_ = ByteArray 3
    LITTLE-ENDIAN.put-uint24 buffer-3_ 0 value
    write-bytes register buffer-3_

  /**
  Writes the $value to the given $register as a signed 24-bit integer.

  Uses little endian.
  */
  write-i24-le register/int value/int -> none:
    if not buffer-3_: buffer-3_ = ByteArray 3
    LITTLE-ENDIAN.put-int24 buffer-3_ 0 value
    write-bytes register buffer-3_

  /**
  Writes the $value to the given $register as an unsigned 24-bit integer.

  Uses big endian.
  */
  write-u24-be register/int value/int -> none:
    if not buffer-3_: buffer-3_ = ByteArray 3
    BIG-ENDIAN.put-uint24 buffer-3_ 0 value
    write-bytes register buffer-3_

  /**
  Writes the $value to the given $register as a signed 24-bit integer.

  Uses big endian.
  */
  write-i24-be register/int value/int -> none:
    if not buffer-3_: buffer-3_ = ByteArray 3
    BIG-ENDIAN.put-int24 buffer-3_ 0 value
    write-bytes register buffer-3_

  /**
  Writes the $value to the given $register as a signed 32-bit integer.

  Uses little endian.
  */
  write-32-le register/int value/int -> none:
    if not buffer-4_: buffer-4_ = ByteArray 4
    LITTLE-ENDIAN.put-int32 buffer-4_ 0 value
    write-bytes register buffer-4_

  /**
  Writes the $value to the given $register as an unsigned 32-bit integer.

  Uses little endian.
  */
  write-u32-le register/int value/int -> none:
    if not buffer-4_: buffer-4_ = ByteArray 4
    LITTLE-ENDIAN.put-uint32 buffer-4_ 0 value
    write-bytes register buffer-4_

  /**
  Writes the $value to the given $register as an unsigned 32-bit integer.

  Uses big endian.
  */
  write-i32-be register/int value/int -> none:
    if not buffer-4_: buffer-4_ = ByteArray 4
    BIG-ENDIAN.put-int32 buffer-4_ 0 value
    write-bytes register buffer-4_

  /**
  Prints register values.

  Prints registers starting at the given $from until the given $to (exclusive) as
    hexadecimal digits.

  The $width indicates the amount of bytes per line.
  */
  dump --from=128 --to=256 --width=8:
    line := ""
    for i := 0; i < to - from; i++:
      if line.size > 0: line += " "
      line += "0x"
      v := read-u8 from + i
      if v < 0x10: line += "0"
      line += v.stringify 16

      if i % width == width - 1:
        print line
        line = ""

    if line.size > 0: print line
