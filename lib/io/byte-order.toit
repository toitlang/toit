// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import bitmap show blit bitmap-zap

/**
Support for byte-order aware manipulation of byte arrays.

The little-endian byte order (generally used by all modern CPUs) stores the
  least-significant byte at the lowest address. Use $LITTLE-ENDIAN (a
  singleton instance of $LittleEndian) to manipulate byte arrays in this order.

The big-endian byte order stores the most-significant byte at the lowest
  address. It is frequently used in networking. Use $BIG-ENDIAN (a
  singleton instance of $BigEndian) to manipulate byte arrays in this order.
*/

/** A constant $LittleEndian singleton. */
LITTLE-ENDIAN/LittleEndian ::= LittleEndian.private_
/** A constant $BigEndian singleton. */
BIG-ENDIAN/BigEndian ::= BigEndian.private_

/**
A byte order class with support for common read and write operations on byte
  arrays.
*/
abstract class ByteOrder:
  /**
  Swaps the byte-order of all 16-bit integers in the $byte-array.
  If the integers were in little-endian order they then are in big-endian byte order
  If the integers were in big-endian order they then are in little-endian byte order.
  */
  static swap-16 byte-array/ByteArray -> none:
    if byte-array.size <= 8:
      for i := 0; i < byte-array.size; i += 2:
        value := LITTLE-ENDIAN.uint16 byte-array i
        BIG-ENDIAN.put-uint16 byte-array i value
      return
    tmp := ByteArray (max byte-array.size 512)
    List.chunk-up 0 byte-array.size 512: | from to size |
      half-size := size / 2
      blit byte-array[from + 1..to] tmp[0..size] half-size --source-pixel-stride=2 --destination-pixel-stride=2
      blit byte-array[from    ..to] tmp[1..size] half-size --source-pixel-stride=2 --destination-pixel-stride=2
      byte-array.replace from tmp 0 size

  /**
  Swaps the byte-order of all 32-bit integers in the $byte-array.
  If the integers were in little-endian order they then are in big-endian byte order
  If the integers were in big-endian order they then are in little-endian byte order.
  */
  static swap-32 byte-array/ByteArray -> none:
    tmp := ByteArray (max byte-array.size 512)
    List.chunk-up 0 byte-array.size 512: | from to size |
      quarter-size := size / 4
      slice := byte-array[from..to]
      buffer := tmp[..size]
      blit slice[3..] buffer      quarter-size --source-pixel-stride=4 --destination-pixel-stride=4
      blit slice[2..] buffer[1..] quarter-size --source-pixel-stride=4 --destination-pixel-stride=4
      blit slice[1..] buffer[2..] quarter-size --source-pixel-stride=4 --destination-pixel-stride=4
      blit slice      buffer[3..] quarter-size --source-pixel-stride=4 --destination-pixel-stride=4
      byte-array.replace from buffer

  /**
  Reads an unsigned 8-bit integer from the $buffer at the $offset.

  The $offset must be a valid index into the $buffer.
  */
  uint8 buffer/ByteArray offset/int -> int:
    return buffer[offset] & 0xff

  /**
  Reads an 8-bit integer from the $buffer at the $offset.

  The $offset must be a valid index into the $buffer.
  */
  int8 buffer/ByteArray offset/int -> int:
    v := buffer[offset] & 0xff
    if v >= 128: return v - 256
    return v

  /**
  Writes the $value to the $buffer at the $offset.
  The $value is written as a signed 8-bit integer.
  Only the 8 least-significant bits of the $value are used, as if truncated with a
    bit-and operation (`& 0xFF`). The given $value is
    allowed to be outside the signed 8-bit integer range. As a consequence, this
    operation behaves the same as $put-uint8. The distinction between those
    two operations is purely for readability and to convey intent when writing the
    values.

  Since single bytes have no byte-order this operation behaves the same on
    $LittleEndian and $BigEndian instances.

  The $offset must be a valid index into the buffer.
  */
  put-int8 buffer/ByteArray offset/int value/int -> none:
    buffer[offset] = value & 0xff

  /**
  Writes the $value to the $buffer at the $offset.
  The $value is written as an unsigned 8-bit integer.

  Only the 8 least-significant bits of the $value are used, as if truncated with a
    bit-and operation (`& 0xFF`). The given $value is
    allowed to be outside the unsigned 8-bit integer range. As a consequence, this
    operation behaves the same as $put-int8. The distinction between those
    two operations is purely for readability and to convey intent when writing the
    values.

  Since single bytes have no byte-order this operation behaves the same on
    $LittleEndian and $BigEndian instances.

  The $offset must be a valid index into the buffer.
  */
  put-uint8 buffer/ByteArray offset/int value/int -> none:
    buffer[offset] = value & 0xff

  /**
  Reads a 16-bit unsigned integer from the $buffer at the $offset.

  The offsets $offset and $offset + 1 must be valid indexes into the $buffer.
  */
  uint16 buffer/ByteArray offset/int -> int:
    return read-uint buffer 2 offset

  /**
  Reads a 16-bit signed integer from the $buffer at the $offset.

  The offsets $offset and $offset + 1 must be valid indexes into the $buffer.
  */
  int16 buffer/ByteArray offset/int -> int:
    return read-int buffer 2 offset

  /**
  Writes the $i16 to the $buffer at the $offset.
  The $i16 is written as a signed 16-bit integer.
  Only the 16 least-significant bits of the $i16 are used, as if truncated with a
    bit-and operation (`& 0xFFFF`). The given $i16 is
    allowed to be outside the signed 16-bit integer range. As a consequence, this
    operation behaves the same as $put-uint16. The distinction between those
    two operations is purely for readability and to convey intent when writing the
    values.

  The offsets $offset and $offset + 1 must be valid indexes into the $buffer.
  */
  put-int16 buffer/ByteArray offset/int i16/int -> none:
    put-uint buffer 2 offset i16


  /**
  Writes the $u16 to the $buffer at the $offset.
  The $u16 is written as a unsigned 16-bit integer.
  Only the 16 least-significant bits of the $u16 are used, as if truncated with a
    bit-and operation (`& 0xFFFF`). The given $u16 is
    allowed to be outside the unsigned 16-bit integer range. As a consequence, this
    operation behaves the same as $put-int16. The distinction between those
    two operations is purely for readability and to convey intent when writing the
    values.

  The offsets $offset and $offset + 1 must be valid indexes into the $buffer.
  */
  put-uint16 buffer/ByteArray offset/int u16/int -> none:
    put-uint buffer 2 offset u16

  /**
  Reads a 24-bit unsigned integer from the $buffer at the $offset.

  The $offset must satisfy: 0 <= $offset <= buffer.size - 3, allowing to read
    3 bytes at index $offset.
  */
  uint24 buffer/ByteArray offset/int -> int:
    return read-uint buffer 3 offset

  /**
  Reads a 24-bit signed integer from the $buffer at the $offset.

  The $offset must satisfy: 0 <= $offset <= buffer.size - 3, allowing to read
    3 bytes at index $offset.
  */
  int24 buffer/ByteArray offset/int -> int:
    return read-int buffer 3 offset

  /**
  Writes the $i24 to the $buffer at the $offset.
  The $i24 is written as a signed 24-bit integer.
  Only the 24 least-significant bits of the $i24 are used, as if truncated with a
    bit-and operation (`& 0xFFFFFF`). The given $i24 is
    allowed to be outside the signed 24-bit integer range. As a consequence, this
    operation behaves the same as $put-uint24. The distinction between those
    two operations is purely for readability and to convey intent when writing the
    values.

  The $offset must satisfy: 0 <= $offset <= buffer.size - 3, allowing to write
    3 bytes at index $offset.
  */
  put-int24 buffer/ByteArray offset/int i24/int -> none:
    put-uint buffer 3 offset i24

  /**
  Writes the $u24 to the $buffer at the $offset.
  The $u24 is written as a unsigned 24-bit integer.
  Only the 24 least-significant bits of the $u24 are used, as if truncated with a
    bit-and operation (`& 0xFFFFFF`). The given $u24 is
    allowed to be outside the unsigned 24-bit integer range. As a consequence, this
    operation behaves the same as $put-int24. The distinction between those
    two operations is purely for readability and to convey intent when writing the
    values.

  The $offset must satisfy: 0 <= $offset <= buffer.size - 3, allowing to write
    3 bytes at index $offset.
  */
  put-uint24 buffer/ByteArray offset/int u24/int -> none:
    put-uint buffer 3 offset u24

  /**
  Reads a 32-bit unsigned integer from the $buffer at the $offset.

  The $offset must satisfy: 0 <= $offset <= buffer.size - 4, allowing to read
    4 bytes at index $offset.
  */
  // Sometimes returns a large integer.
  uint32 buffer/ByteArray offset/int -> int:
    return read-uint buffer 4 offset

  /**
  Reads a 32-bit signed integer from the $buffer at the $offset.

  The $offset must satisfy: 0 <= $offset <= buffer.size - 4, allowing to read
    4 bytes at index $offset.
  */
  // Sometimes returns a large integer.
  int32 buffer/ByteArray offset/int -> int:
    return read-int buffer 4 offset

  /**
  Writes the $i32 to the $buffer at the $offset.
  The $i32 is written as a signed 32-bit integer.
  Only the 32 least-significant bits of the $i32 are used, as if truncated with a
    bit-and operation (`& 0xFFFF_FFFF`). The given $i32 is
    allowed to be outside the signed 32-bit integer range. As a consequence, this
    operation behaves the same as $put-uint32. The distinction between those
    two operations is purely for readability and to convey intent when writing the
    values.

  The $offset must satisfy: 0 <= $offset <= buffer.size - 4, allowing to write
    4 bytes at index $offset.
  */
  put-int32 buffer/ByteArray offset/int i32/int -> none:
    put-uint buffer 4 offset i32

  /**
  Writes the $u32 to the $buffer at the $offset.
  The $u32 is written as a unsigned 32-bit integer.
  Only the 32 least-significant bits of the $u32 are used, as if truncated with a
    bit-and operation (`& 0xFFFF_FFFF`). The given $u32 is
    allowed to be outside the unsigned 32-bit integer range. As a consequence, this
    operation behaves the same as $put-int32. The distinction between those
    two operations is purely for readability and to convey intent when writing the
    values.

  The $offset must satisfy: 0 <= $offset <= buffer.size - 4, allowing to write
    4 bytes at index $offset.
  */
  put-uint32 buffer/ByteArray offset/int u32/int -> none:
    put-uint buffer 4 offset u32

  /**
  Reads a 64-bit signed integer from the $buffer at the $offset.

  The $offset must satisfy: 0 <= $offset <= buffer.size - 8, allowing to read
    8 bytes at index $offset.
  */
  // Sometimes returns a large integer.
  int64 buffer/ByteArray offset/int -> int:
    return read-int buffer 8 offset

  /**
  Writes the $i64 to the $buffer at the $offset.
  The $i64 is written as a signed 64-bit integer.

  The $offset must satisfy: 0 <= $offset <= buffer.size - 8, allowing to write
    8 bytes at index $offset.
  */
  put-int64 buffer/ByteArray offset/int i64/int -> none:
    put-uint buffer 8 offset i64

  // There is no uint64 version, as the language only supports int64.

  /**
  Reads a 64-bit floating point number from the $buffer at the $offset.

  The $offset must satisfy: 0 <= $offset <= buffer.size - 8, allowing to read
    8 bytes at index $offset.
  */
  float64 buffer/ByteArray offset/int -> float:
    bits := int64 buffer offset
    return float.from-bits bits

  /**
  Writes the $f64 to the $buffer at the $offset.
  The $f64 is written as a 64-bit floating point number.

  The $offset must satisfy: 0 <= $offset <= buffer.size - 8, allowing to write
    8 bytes at index $offset.
  */
  put-float64 buffer/ByteArray offset/int f64/float -> none:
    bits := f64.bits
    put-int64 buffer offset bits

  /**
  Reads a 32-bit floating point number from the $buffer at the $offset.

  The $offset must satisfy: 0 <= $offset <= buffer.size - 8, allowing to read
    8 bytes at index $offset.
  */
  float32 buffer/ByteArray offset/int -> float:
    bits := uint32 buffer offset
    return float.from-bits32 bits

  /**
  Writes the $f32 to the $buffer at the $offset.
  The $f32 is written as a 32-bit floating point number.

  The $offset must satisfy: 0 <= $offset <= buffer.size - 8, allowing to write
    8 bytes at index $offset.
  */
  put-float32 buffer/ByteArray offset/int f32/float -> none:
    bits := f32.bits32
    put-uint32 buffer offset bits

  /**
  Reads $size-in-bytes from the $buffer at the $offset as a signed integer.

  The $offset must satisfy: 0 <= $offset <= buffer - $size-in-bytes,
    allowing to read $size-in-bytes bytes at index $offset.
  */
  abstract read-int buffer/ByteArray size-in-bytes/int offset/int -> int

  /**
  Reads $size-in-bytes from the $buffer at the $offset as an unsigned integer.

  The $offset must satisfy: 0 <= $offset <= buffer.size - $size-in-bytes,
    allowing to read $size-in-bytes bytes at index $offset.
  */
  abstract read-uint buffer/ByteArray size-in-bytes/int offset/int -> int

  /**
  Writes the $value in the $buffer at the $offset using the
    $size-in-bytes bytes of the $buffer.

  The $offset must satisfy: 0 <= $offset <= buffer.size - $size-in-bytes,
    allowing to write size_in_byte bytes at index $offset.
  */
  abstract put-uint buffer/ByteArray size-in-bytes/int offset/int value/int -> none

/**
Support for little endian byte order.

Reuse an instance for multiple accesses or use the singleton $LITTLE-ENDIAN
  to avoid multiple unnecessary object allocations.
*/
class LittleEndian extends ByteOrder:
  constructor.private_:

  /** See $super. */
  read-int buffer/ByteArray size-in-bytes/int offset/int -> int:
    #primitive.core.read-int-little-endian:
      start := offset + size-in-bytes - 1
      end := offset  // Inclusive.
      result := int8 buffer start--
      for i := start; i >= end; i--:
        result <<= 8
        result |= uint8 buffer i
      return result

  /** See $super. */
  read-uint buffer/ByteArray size-in-bytes/int offset/int -> int:
    #primitive.core.read-uint-little-endian:
      start := offset + size-in-bytes - 1
      end := offset  // Inclusive.
      result := uint8 buffer start--
      for i := start; i >= end; i--:
        result <<= 8
        result |= uint8 buffer i
      return result

  /** See $super. */
  put-uint buffer/ByteArray size-in-bytes/int offset/int value/int -> none:
    #primitive.core.put-uint-little-endian:
      size-in-bytes.repeat:
        put-uint8 buffer (offset + it) value
        value = value >>> 8

  /**
  Writes the $f64 to the $buffer at the $offset.
  The $f64 is written as a 64-bit floating point number.

  The $offset must satisfy: 0 <= $offset <= buffer.size - 8, allowing to write
    8 bytes at index $offset.
  */
  put-float64 buffer/ByteArray offset/int f64/float -> none:
    #primitive.core.put-float-64-little-endian:
      bits := f64.bits
      put-int64 buffer offset bits

  /**
  Writes the $f32 to the $buffer at the $offset.
  The $f32 is written as a 32-bit floating point number.

  The $offset must satisfy: 0 <= $offset <= buffer.size - 8, allowing to write
    8 bytes at index $offset.
  */
  put-float32 buffer/ByteArray offset/int f32/float -> none:
    #primitive.core.put-float-32-little-endian:
      bits := f32.bits32
      put-int32 buffer offset bits

/**
Support for big endian byte order.

Reuse an instance for multiple accesses or use the singleton $LITTLE-ENDIAN
  to avoid multiple unnecessary object allocations.
*/
class BigEndian extends ByteOrder:
  constructor.private_:

  /** See $super. */
  read-int buffer/ByteArray size-in-bytes/int offset/int -> int:
    #primitive.core.read-int-big-endian:
      result := int8 buffer offset
      (size-in-bytes - 1).repeat:
        result <<= 8
        result |= uint8 buffer (offset + it + 1)
      return result

  /** See $super. */
  read-uint buffer/ByteArray size-in-bytes/int offset/int -> int:
    #primitive.core.read-uint-big-endian:
      result := uint8 buffer offset
      (size-in-bytes - 1).repeat:
        result <<= 8
        result |= uint8 buffer (offset + it + 1)
      return result

  /** See $super. */
  put-uint buffer/ByteArray size-in-bytes/int offset/int value/int -> none:
    #primitive.core.put-uint-big-endian:
      for i := offset + size-in-bytes - 1; i >= offset; i--:
        put-uint8 buffer i value
        value = value >>> 8
