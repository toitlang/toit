// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import binary show LITTLE_ENDIAN BIG_ENDIAN

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
  abstract read_bytes register/int count/int -> ByteArray
  /**
  Variant of $(read_bytes register count)

  Calls the $failure block in case of an exception.
  */
  abstract read_bytes register/int count/int [failure] -> ByteArray
  /** Writes the $data to the given $register. */
  abstract write_bytes register/int data/ByteArray -> none

  buffer_1_/ByteArray? := null
  buffer_2_/ByteArray? := null
  buffer_3_/ByteArray? := null
  buffer_4_/ByteArray? := null

  /** Reads an unsigned 8-bit integer from the $register. */
  read_u8 register/int -> int:
    bytes := read_bytes register 1
    return bytes[0]

  /** Reads a signed 8-bit integer from the $register. */
  read_i8 register/int -> int:
    v := read_u8 register
    if v >= 128: return v - 256
    return v

  /**
  Reads a signed 16-bit integer from the $register.

  Uses little endian.
  */
  read_i16_le register/int -> int:
    bytes := read_bytes register 2
    return LITTLE_ENDIAN.int16 bytes 0

  /**
  Reads a signed 16-bit integer from the $register.

  Uses big endian.
  */
  read_i16_be register/int -> int:
    bytes := read_bytes register 2
    return BIG_ENDIAN.int16 bytes 0

  /**
  Reads an unsigned 16-bit integer from the $register.

  Uses little endian.
  */
  read_u16_le register/int -> int:
    bytes := read_bytes register 2
    return LITTLE_ENDIAN.uint16 bytes 0

  /**
  Reads an unsigned 16-bit integer from the $register.

  Uses big endian.
  */
  read_u16_be register/int -> int:
    bytes := read_bytes register 2
    return BIG_ENDIAN.uint16 bytes 0

  /**
  Reads an unsigned 16-bit integer from the $register.

  Uses little endian.

  Calls the $failure block in case of an exception.
  */
  read_u16_be register/int [failure] -> int:
    bytes := read_bytes register 2: return failure.call it
    return BIG_ENDIAN.uint16 bytes 0


  /**
  Reads a signed 24-bit integer from the $register.

  Uses little endian.
  */
  read_i24_le register/int -> int:
    bytes := read_bytes register 3
    return LITTLE_ENDIAN.int24 bytes 0

  /**
  Reads a signed 24-bit integer from the $register.

  Uses big endian.
  */
  read_i24_be register/int -> int:
    bytes := read_bytes register 3
    return BIG_ENDIAN.int24 bytes 0

  /**
  Reads an unsigned 24-bit integer from the $register.

  Uses little endian.
  */
  read_u24_le register/int -> int:
    bytes := read_bytes register 3
    return LITTLE_ENDIAN.uint24 bytes 0

  /**
  Reads an unsigned 24-bit integer from the $register.

  Uses big endian.
  */
  read_u24_be register/int -> int:
    bytes := read_bytes register 3
    return BIG_ENDIAN.uint24 bytes 0

  /**
  Reads a signed 32-bit integer from the $register.

  Uses little endian.
  */
  read_i32_le register/int -> int:
    bytes := read_bytes register 4
    return LITTLE_ENDIAN.int32 bytes 0

  /**
  Reads a signed 32-bit integer from the $register.

  Uses big endian.
  */
  read_i32_be register/int -> int:
    bytes := read_bytes register 4
    return BIG_ENDIAN.int32 bytes 0

  /**
  Reads an unsigned 32-bit integer from the $register.

  Uses little endian.
  */
  read_u32_le register/int -> int:
    bytes := read_bytes register 4
    return LITTLE_ENDIAN.uint32 bytes 0

  /**
  Reads an unsigned 32-bit integer from the $register.

  Uses big endian.
  */
  read_u32_be register/int -> int:
    bytes := read_bytes register 4
    return BIG_ENDIAN.uint32 bytes 0

  /**
  Writes the $value to the given $register as an unsigned 8-bit integer.
  */
  write_u8 register/int value/int -> none:
    if not buffer_1_: buffer_1_ = ByteArray 1
    buffer_1_[0] = value
    write_bytes register buffer_1_

  /** Writes the $value to the given $register as a signed 8-bit integer. */
  write_i8 register/int value/int -> none:
    if not -128 <= value <= 127: throw "OUT_OF_BOUNDS"
    if not buffer_1_: buffer_1_ = ByteArray 1
    buffer_1_[0] = value
    write_bytes register buffer_1_

  /**
  Writes the $value to the given $register as an unsigned 16-bit integer.

  Uses little endian.
  */
  write_u16_le register/int value/int -> none:
    if not buffer_2_: buffer_2_ = ByteArray 2
    LITTLE_ENDIAN.put_uint16 buffer_2_ 0 value
    write_bytes register buffer_2_

  /**
  Writes the $value to the given $register as a signed 16-bit integer.

  Uses little endian.
  */
  write_i16_le register/int value/int -> none:
    if not buffer_2_: buffer_2_ = ByteArray 2
    LITTLE_ENDIAN.put_int16 buffer_2_ 0 value
    write_bytes register buffer_2_

  /**
  Writes the $value to the given $register as an unsigned 16-bit integer.

  Uses big endian.
  */
  write_u16_be register/int value/int -> none:
    if not buffer_2_: buffer_2_ = ByteArray 2
    BIG_ENDIAN.put_uint16 buffer_2_ 0 value
    write_bytes register buffer_2_

  /**
  Writes the $value to the given $register as a signed 16-bit integer.

  Uses big endian.
  */
  write_i16_be register/int value/int -> none:
    if not buffer_2_: buffer_2_ = ByteArray 2
    BIG_ENDIAN.put_int16 buffer_2_ 0 value
    write_bytes register buffer_2_

  /**
  Writes the $value to the given $register as an unsigned 24-bit integer.

  Uses little endian.
  */
  write_u24_le register/int value/int -> none:
    if not buffer_3_: buffer_3_ = ByteArray 3
    LITTLE_ENDIAN.put_uint24 buffer_3_ 0 value
    write_bytes register buffer_3_

  /**
  Writes the $value to the given $register as a signed 24-bit integer.

  Uses little endian.
  */
  write_i24_le register/int value/int -> none:
    if not buffer_3_: buffer_3_ = ByteArray 3
    LITTLE_ENDIAN.put_int24 buffer_3_ 0 value
    write_bytes register buffer_3_

  /**
  Writes the $value to the given $register as an unsigned 24-bit integer.

  Uses big endian.
  */
  write_u24_be register/int value/int -> none:
    if not buffer_3_: buffer_3_ = ByteArray 3
    BIG_ENDIAN.put_uint24 buffer_3_ 0 value
    write_bytes register buffer_3_

  /**
  Writes the $value to the given $register as a signed 24-bit integer.

  Uses big endian.
  */
  write_i24_be register/int value/int -> none:
    if not buffer_3_: buffer_3_ = ByteArray 3
    BIG_ENDIAN.put_int24 buffer_3_ 0 value
    write_bytes register buffer_3_

  /**
  Writes the $value to the given $register as a signed 32-bit integer.

  Uses little endian.
  */
  write_32_le register/int value/int -> none:
    if not buffer_4_: buffer_4_ = ByteArray 4
    LITTLE_ENDIAN.put_int32 buffer_4_ 0 value
    write_bytes register buffer_4_

  /**
  Writes the $value to the given $register as an unsigned 32-bit integer.

  Uses little endian.
  */
  write_u32_le register/int value/int -> none:
    if not buffer_4_: buffer_4_ = ByteArray 4
    LITTLE_ENDIAN.put_uint32 buffer_4_ 0 value
    write_bytes register buffer_4_

  /**
  Writes the $value to the given $register as an unsigned 32-bit integer.

  Uses big endian.
  */
  write_i32_be register/int value/int -> none:
    if not buffer_4_: buffer_4_ = ByteArray 4
    BIG_ENDIAN.put_int32 buffer_4_ 0 value
    write_bytes register buffer_4_

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
      v := read_u8 from + i
      if v < 0x10: line += "0"
      line += v.stringify 16

      if i % width == width - 1:
        print line
        line = ""

    if line.size > 0: print line
