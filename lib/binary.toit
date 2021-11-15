// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import bitmap show blit bitmap_zap

/**
Support for byte-order aware manipulation of byte arrays.

The little-endian byte order (generally used by all modern CPUs) stores the
  least-significant byte at the lowest address. Use $LITTLE_ENDIAN (a
  singleton instance of $LittleEndian) to manipulate byte arrays in this order.

The big-endian byte order stores the most-significant byte at the lowest
  address. It is frequently used in networking. Use $BIG_ENDIAN (a
  singleton instance of $BigEndian) to manipulate byte arrays in this order.
*/

/** The minimum signed 8-bit integer value. */
INT8_MIN ::= -128
/** The maximum signed 8-bit integer value. */
INT8_MAX ::= 127
/** The minimum signed 16-bit integer value. */
INT16_MIN ::= -32_768
/** The maximum signed 16-bit integer value. */
INT16_MAX ::= 32_767
/** The minimum signed 24-bit integer value. */
INT24_MIN ::= -8_388_606
/** The maximum signed 24-bit integer value. */
INT24_MAX ::= 8_388_607
/** The minimum signed 32-bit integer value. */
INT32_MIN ::= -2_147_483_648
/** The maximum signed 32-bit integer values. */
INT32_MAX ::= 2_147_483_647

/** The maximum unsigned 8-bit integer values. */
UINT8_MAX ::= 255
/** The maximum unsigned 16-bit integer values. */
UINT16_MAX ::= 65_535
/** The maximum unsigned 24-bit integer values. */
UINT24_MAX ::= 16777216
/** The maximum unsigned 32-bit integer values. */
UINT32_MAX ::= 4_294_967_295

/** A constant $LittleEndian singleton. */
LITTLE_ENDIAN/LittleEndian ::= LittleEndian.private_
/** A constant $BigEndian singleton. */
BIG_ENDIAN/BigEndian ::= BigEndian.private_

/**
A byte order class with support for common read and write operations on byte
  arrays.
*/
abstract class ByteOrder:
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
    operation behaves the same as $put_uint8. The distinction between those
    two operations is purely for readability and to convey intent when writing the
    values.

  Since single bytes have no byte-order this operation behaves the same on
    $LittleEndian and $BigEndian instances.

  The $offset must be a valid index into the buffer.
  */
  put_int8 buffer/ByteArray offset/int value/int -> none:
    buffer[offset] = value & 0xff

  /**
  Writes the $value to the $buffer at the $offset.
  The $value is written as an unsigned 8-bit integer.

  Only the 8 least-significant bits of the $value are used, as if truncated with a
    bit-and operation (`& 0xFF`). The given $value is
    allowed to be outside the unsigned 8-bit integer range. As a consequence, this
    operation behaves the same as $put_int8. The distinction between those
    two operations is purely for readability and to convey intent when writing the
    values.

  Since single bytes have no byte-order this operation behaves the same on
    $LittleEndian and $BigEndian instances.

  The $offset must be a valid index into the buffer.
  */
  put_uint8 buffer/ByteArray offset/int value/int -> none:
    buffer[offset] = value & 0xff

  /**
  Reads a 16-bit unsigned integer from the $buffer at the $offset.

  The offsets $offset and $offset + 1 must be valid indexes into the $buffer.
  */
  uint16 buffer/ByteArray offset/int -> int:
    return read_uint buffer 2 offset

  /**
  Reads a 16-bit signed integer from the $buffer at the $offset.

  The offsets $offset and $offset + 1 must be valid indexes into the $buffer.
  */
  int16 buffer/ByteArray offset/int -> int:
    return read_int buffer 2 offset

  /**
  Writes the $i16 to the $buffer at the $offset.
  The $i16 is written as a signed 16-bit integer.
  Only the 16 least-significant bits of the $i16 are used, as if truncated with a
    bit-and operation (`& 0xFFFF`). The given $i16 is
    allowed to be outside the signed 16-bit integer range. As a consequence, this
    operation behaves the same as $put_uint16. The distinction between those
    two operations is purely for readability and to convey intent when writing the
    values.

  The offsets $offset and $offset + 1 must be valid indexes into the $buffer.
  */
  put_int16 buffer/ByteArray offset/int i16/int -> none:
    put_uint buffer 2 offset i16


  /**
  Writes the $u16 to the $buffer at the $offset.
  The $u16 is written as a unsigned 16-bit integer.
  Only the 16 least-significant bits of the $u16 are used, as if truncated with a
    bit-and operation (`& 0xFFFF`). The given $u16 is
    allowed to be outside the unsigned 16-bit integer range. As a consequence, this
    operation behaves the same as $put_int16. The distinction between those
    two operations is purely for readability and to convey intent when writing the
    values.

  The offsets $offset and $offset + 1 must be valid indexes into the $buffer.
  */
  put_uint16 buffer/ByteArray offset/int u16/int -> none:
    put_uint buffer 2 offset u16

  /**
  Reads a 24-bit unsigned integer from the $buffer at the $offset.

  The $offset must satisfy: 0 <= $offset <= buffer.size - 3, allowing to read
    3 bytes at index $offset.
  */
  uint24 buffer/ByteArray offset/int -> int:
    return read_uint buffer 3 offset

  /**
  Reads a 24-bit signed integer from the $buffer at the $offset.

  The $offset must satisfy: 0 <= $offset <= buffer.size - 3, allowing to read
    3 bytes at index $offset.
  */
  int24 buffer/ByteArray offset/int -> int:
    return read_int buffer 3 offset

  /**
  Writes the $i24 to the $buffer at the $offset.
  The $i24 is written as a signed 24-bit integer.
  Only the 24 least-significant bits of the $i24 are used, as if truncated with a
    bit-and operation (`& 0xFFFFFF`). The given $i24 is
    allowed to be outside the signed 24-bit integer range. As a consequence, this
    operation behaves the same as $put_uint24. The distinction between those
    two operations is purely for readability and to convey intent when writing the
    values.

  The $offset must satisfy: 0 <= $offset <= buffer.size - 3, allowing to write
    3 bytes at index $offset.
  */
  put_int24 buffer/ByteArray offset/int i24/int -> none:
    put_uint buffer 3 offset i24

  /**
  Writes the $u24 to the $buffer at the $offset.
  The $u24 is written as a unsigned 24-bit integer.
  Only the 24 least-significant bits of the $u24 are used, as if truncated with a
    bit-and operation (`& 0xFFFFFF`). The given $u24 is
    allowed to be outside the unsigned 24-bit integer range. As a consequence, this
    operation behaves the same as $put_int24. The distinction between those
    two operations is purely for readability and to convey intent when writing the
    values.

  The $offset must satisfy: 0 <= $offset <= buffer.size - 3, allowing to write
    3 bytes at index $offset.
  */
  put_uint24 buffer/ByteArray offset/int u24/int -> none:
    put_uint buffer 3 offset u24

  /**
  Reads a 32-bit unsigned integer from the $buffer at the $offset.

  The $offset must satisfy: 0 <= $offset <= buffer.size - 4, allowing to read
    4 bytes at index $offset.
  */
  // Sometimes returns a large integer.
  uint32 buffer/ByteArray offset/int -> int:
    return read_uint buffer 4 offset

  /**
  Reads a 32-bit signed integer from the $buffer at the $offset.

  The $offset must satisfy: 0 <= $offset <= buffer.size - 4, allowing to read
    4 bytes at index $offset.
  */
  // Sometimes returns a large integer.
  int32 buffer/ByteArray offset/int -> int:
    return read_int buffer 4 offset

  /**
  Writes the $i32 to the $buffer at the $offset.
  The $i32 is written as a signed 32-bit integer.
  Only the 32 least-significant bits of the $i32 are used, as if truncated with a
    bit-and operation (`& 0xFFFF_FFFF`). The given $i32 is
    allowed to be outside the signed 32-bit integer range. As a consequence, this
    operation behaves the same as $put_uint32. The distinction between those
    two operations is purely for readability and to convey intent when writing the
    values.

  The $offset must satisfy: 0 <= $offset <= buffer.size - 4, allowing to write
    4 bytes at index $offset.
  */
  put_int32 buffer/ByteArray offset/int i32/int -> none:
    put_uint buffer 4 offset i32

  /**
  Writes the $u32 to the $buffer at the $offset.
  The $u32 is written as a unsigned 32-bit integer.
  Only the 32 least-significant bits of the $u32 are used, as if truncated with a
    bit-and operation (`& 0xFFFF_FFFF`). The given $u32 is
    allowed to be outside the unsigned 32-bit integer range. As a consequence, this
    operation behaves the same as $put_int32. The distinction between those
    two operations is purely for readability and to convey intent when writing the
    values.

  The $offset must satisfy: 0 <= $offset <= buffer.size - 4, allowing to write
    4 bytes at index $offset.
  */
  put_uint32 buffer/ByteArray offset/int u32/int -> none:
    put_uint buffer 4 offset u32

  /**
  Reads a 64-bit unsigned integer from the $buffer at the $offset.

  The $offset must satisfy: 0 <= $offset <= buffer.size - 8, allowing to read
    8 bytes at index $offset.
  */
  // Sometimes returns a large integer.
  int64 buffer/ByteArray offset/int -> int:
    return read_int buffer 8 offset

  /**
  Writes the $i64 to the $buffer at the $offset.
  The $i64 is written as a signed 64-bit integer.

  The $offset must satisfy: 0 <= $offset <= buffer.size - 8, allowing to write
    8 bytes at index $offset.
  */
  put_int64 buffer/ByteArray offset/int i64/int -> none:
    put_uint buffer 8 offset i64

  // There is no uint64 version, as the language only supports int64.

  /**
  Reads a 64-bit floating point number from the $buffer at the $offset.

  The $offset must satisfy: 0 <= $offset <= buffer.size - 8, allowing to read
    8 bytes at index $offset.
  */
  float64 buffer/ByteArray offset/int -> float:
    bits := int64 buffer offset
    return float.from_bits bits

  /**
  Writes the $f64 to the $buffer at the $offset.
  The $f64 is written as a 64-bit floating point number.

  The $offset must satisfy: 0 <= $offset <= buffer.size - 8, allowing to write
    8 bytes at index $offset.
  */
  put_float64 buffer/ByteArray offset/int f64/float -> none:
    bits := f64.bits
    put_int64 buffer offset bits

  /**
  Reads a 32-bit floating point number from the $buffer at the $offset.

  The $offset must satisfy: 0 <= $offset <= buffer.size - 8, allowing to read
    8 bytes at index $offset.
  */
  float32 buffer/ByteArray offset/int -> float:
    bits := int32 buffer offset
    return float.from_bits32 bits

  /**
  Writes the $f32 to the $buffer at the $offset.
  The $f32 is written as a 32-bit floating point number.

  The $offset must satisfy: 0 <= $offset <= buffer.size - 8, allowing to write
    8 bytes at index $offset.
  */
  put_float32 buffer/ByteArray offset/int f32/float -> none:
    bits := f32.bits32
    put_int32 buffer offset bits

  /**
  Reads $size_in_bytes from the $buffer at the $offset as a signed integer.

  The $offset must satisfy: 0 <= $offset <= buffer - $size_in_bytes,
    allowing to read $size_in_bytes bytes at index $offset.
  */
  abstract read_int buffer/ByteArray size_in_bytes/int offset/int -> int

  /**
  Reads $size_in_bytes from the $buffer at the $offset as an unsigned integer.

  The $offset must satisfy: 0 <= $offset <= buffer.size - $size_in_bytes,
    allowing to read $size_in_bytes bytes at index $offset.
  */
  abstract read_uint buffer/ByteArray size_in_bytes/int offset/int -> int

  /**
  Writes the $value in the $buffer at the $offset using the
    $size_in_bytes bytes of the $buffer.

  The $offset must satisfy: 0 <= $offset <= buffer.size - $size_in_bytes,
    allowing to write size_in_byte bytes at index $offset.
  */
  abstract put_uint buffer/ByteArray size_in_bytes/int offset/int value/int -> none

/**
Support for little endian byte order.

Reuse an instance for multiple accesses or use the singleton $LITTLE_ENDIAN
  to avoid multiple unnecessary object allocations.
*/
class LittleEndian extends ByteOrder:
  /** Deprecated. Use $LITTLE_ENDIAN. */
  constructor:

  constructor.private_:

  /** See $super. */
  read_int buffer/ByteArray size_in_bytes/int offset/int -> int:
    #primitive.core.read_int_little_endian:
      start := offset + size_in_bytes - 1
      end := offset  // Inclusive.
      result := int8 buffer start--
      for i := start; i >= end; i--:
        result <<= 8
        result |= uint8 buffer i
      return result

  /** See $super. */
  read_uint buffer/ByteArray size_in_bytes/int offset/int -> int:
    #primitive.core.read_uint_little_endian:
      start := offset + size_in_bytes - 1
      end := offset  // Inclusive.
      result := uint8 buffer start--
      for i := start; i >= end; i--:
        result <<= 8
        result |= uint8 buffer i
      return result

  /** See $super. */
  put_uint buffer/ByteArray size_in_bytes/int offset/int value/int -> none:
    #primitive.core.put_uint_little_endian:
      size_in_bytes.repeat:
        put_uint8 buffer (offset + it) value
        value = value >>> 8

  /**
  Writes the $f64 to the $buffer at the $offset.
  The $f64 is written as a 64-bit floating point number.

  The $offset must satisfy: 0 <= $offset <= buffer.size - 8, allowing to write
    8 bytes at index $offset.
  */
  put_float64 buffer/ByteArray offset/int f64/float -> none:
    #primitive.core.put_float_64_little_endian:
      bits := f64.bits
      put_int64 buffer offset bits

  /**
  Writes the $f32 to the $buffer at the $offset.
  The $f32 is written as a 32-bit floating point number.

  The $offset must satisfy: 0 <= $offset <= buffer.size - 8, allowing to write
    8 bytes at index $offset.
  */
  put_float32 buffer/ByteArray offset/int f32/float -> none:
    #primitive.core.put_float_32_little_endian:
      bits := f32.bits32
      put_int32 buffer offset bits

/**
Support for big endian byte order.

Reuse an instance for multiple accesses or use the singleton $LITTLE_ENDIAN
  to avoid multiple unnecessary object allocations.
*/
// TODO(4199): Make constructor private.
class BigEndian extends ByteOrder:
  /** Deprecated. Use $BIG_ENDIAN. */
  constructor:

  constructor.private_:

  /** See $super. */
  read_int buffer/ByteArray size_in_bytes/int offset/int -> int:
    #primitive.core.read_int_big_endian:
      result := int8 buffer offset
      (size_in_bytes - 1).repeat:
        result <<= 8
        result |= uint8 buffer (offset + it + 1)
      return result

  /** See $super. */
  read_uint buffer/ByteArray size_in_bytes/int offset/int -> int:
    #primitive.core.read_uint_big_endian:
      result := uint8 buffer offset
      (size_in_bytes - 1).repeat:
        result <<= 8
        result |= uint8 buffer (offset + it + 1)
      return result

  /** See $super. */
  put_uint buffer/ByteArray size_in_bytes/int offset/int value/int -> none:
    #primitive.core.put_uint_big_endian:
      for i := offset + size_in_bytes - 1; i >= offset; i--:
        put_uint8 buffer i value
        value = value >>> 8

/**
Swaps the byte-order of all 16-bit integers in the $byte_array.
If the integers were in little-endian order they then are in big-endian byte order
If the integers were in big-endian order they then are in little-endian byte order.
*/
byte_swap_16 byte_array/ByteArray -> none:
  if byte_array.size <= 8:
    for i := 0; i < byte_array.size; i += 2:
      value := LITTLE_ENDIAN.uint16 byte_array i
      BIG_ENDIAN.put_uint16 byte_array i value
    return
  tmp := ByteArray
    max byte_array.size 512
  List.chunk_up 0 byte_array.size 512: | from to size |
    blit byte_array[from + 1..to] tmp[0..size] size/2 --source_pixel_stride=2 --destination_pixel_stride=2
    blit byte_array[from    ..to] tmp[1..size] size/2 --source_pixel_stride=2 --destination_pixel_stride=2
    byte_array.replace from tmp 0 size

/**
Swaps the byte-order of all 32-bit integers in the $byte_array.
If the integers were in little-endian order they then are in big-endian byte order
If the integers were in big-endian order they then are in little-endian byte order.
*/
byte_swap_32 byte_array/ByteArray -> none:
  tmp := ByteArray
    max byte_array.size 512
  List.chunk_up 0 byte_array.size 512: | from to size |
    slice := byte_array[from..to]
    buffer := tmp[..size]
    blit slice[3..] buffer      size/4 --source_pixel_stride=4 --destination_pixel_stride=4
    blit slice[2..] buffer[1..] size/4 --source_pixel_stride=4 --destination_pixel_stride=4
    blit slice[1..] buffer[2..] size/4 --source_pixel_stride=4 --destination_pixel_stride=4
    blit slice      buffer[3..] size/4 --source_pixel_stride=4 --destination_pixel_stride=4
    byte_array.replace from buffer
