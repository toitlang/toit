// Copyright (C) 2024 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .byte-order
import .data
import .writer

/**
A buffer that can be used to build byte data.

# Aliases
- `BytesBuilder`: Dart
- `ByteArrayOutputStream`: Java
*/
class Buffer extends CloseableWriter:
  static INITIAL-BUFFER-SIZE_ ::= 64
  static MIN-BUFFER-GROWTH_ ::= 64

  init-size_/int
  offset_ := 0
  buffer_/ByteArray := ?
  is-growable_/bool := ?

  /**
  The number of bytes that have been written into the buffer.
  If the buffer was cleared, then this value is reset to 0.
  */
  processed -> int:
    // Ignore the processed_ counter from the superclass, which
    // is not consistently updated.
    return offset_

  /**
  Constructs a new buffer.

  The backing byte array is allocated with a default size and will grow if needed.
  */
  constructor:
    return Buffer (ByteArray INITIAL-BUFFER-SIZE_) --growable

  /**
  Constructs a new buffer, using the given $bytes as backing array.

  If $growable is true, then the $bytes array might be replaced with a bigger one
    if needed.

  The current backing array can be accessed with $backing-array.
  A view, only containing the data that has been written so far, can be accessed
    with $bytes.
  */
  constructor bytes/ByteArray --growable/bool=false:
    buffer_ = bytes
    is-growable_ = growable
    init-size_ = bytes.size

  /**
  Constructs a new buffer with the given initial $size.

  If $growable is true (the default), then the backing array might be replaced
    with a bigger one if needed.

  The current backing array can be accessed with $backing-array.
  A view, only containing the data that has been written so far, can be accessed
    with $bytes.
  */
  constructor.with-capacity size/int --growable/bool=true:
    buffer_ = ByteArray size
    init-size_ = size
    is-growable_ = growable

  /**
  Whether this instance is allowed to replace the backing store with a bigger one.

  If false, then the $backing-array is always equal to the array that was passed
    to the constructor.
  */
  is-growable -> bool:
    return is-growable_

  /**
  The amount of bytes that have been written to this buffer.

  This is not necessarily the size of the backing array.
  */
  size -> int:
    return offset_

  /**
  The backing array of this buffer.

  If $is-growable is false, always returns the array that was passed to the constructor.
  This array might have a bigger size than the number of bytes that have been written.
  */
  backing-array -> ByteArray:
    return buffer_

  /**
  A view of the backing array that only contains the bytes that have been written so far.
  */
  bytes -> ByteArray:
    return buffer_[..offset_]

  /**
  Converts the consumed data to a string.
  This operation is equivalent to `bytes.to-string`.
  */
  to-string -> string:
    return bytes.to-string

  /**
  Reserves $amount bytes.

  Ensures that the backing array has $amount unused bytes available.
  If this is not the case replaces the backing array with a bigger one. In this
    case this instance must be growable. (See $is-growable.)

  This method is purely for efficiency, so that this consumer doesn't need to
    regrow its internal backing store too often.
  */
  reserve amount/int -> none:
    ensure_ amount

  /**
  Changes the size of the buffer to the given $new-size.

  If $new-size is smaller than the current size, then the buffer is truncated.
  If $new-size is bigger than the current size, then the buffer is padded with zeros.
  */
  resize new-size/int -> none:
    ensure_ new-size
    if new-size < offset_:
      // Clear the bytes that are no longer part of the buffer.
      buffer_.fill --from=new-size --to=offset_ 0
    offset_ = new-size

  /**
  Grows the buffer by the given $amount.

  The new bytes are initialized to $value.
  */
  grow-by amount/int --value/int=0 -> none:
    ensure_ amount
    buffer_.fill --from=offset_ --to=(offset_ + amount) value
    offset_ += amount

  /**
  Pads the buffer to the given $size.

  If the buffer is already bigger than $size, then this method does nothing.
  Fills the new bytes with the given $value.
  */
  pad-to --size/int --value/int=0 -> none:
    if size <= offset_: return
    grow-by size - offset_ --value=value

  /**
  Pads the buffer to the given $alignment.

  If the buffer is already aligned, then this method does nothing.
  Fills the new bytes with the given $value.
  */
  pad --alignment/int --value/int=0 -> none:
    pad-to --size=(round-up offset_ alignment) --value=value

  /**
  Closes this instance.

  If this instance is growable, trims the backing store to avoid waste.
  See $is-growable.
  */
  close -> none:
    super

  /**
  Resets this instance, discarding all accumulated data.
  */
  clear -> none:
    offset_ = 0

  ensure_ amount/int:
    new-minimum-size := offset_ + amount
    if new-minimum-size <= backing-array.size: return

    if not is-growable_: throw "BUFFER_FULL"

    // If we are ensuring a very big size, then make the buffer fit exactly.
    // This is good for ubjson encodings that end with a large byte array,
    // because there is no waste.  Otherwise grow by at least a factor (of 1.5)
    // to avoid quadratic running times.
    new-size := max
      buffer_.size +
        max
          buffer_.size >> 1
          MIN-BUFFER-GROWTH_
      new-minimum-size

    assert: offset_ + amount  <= new-size

    new := ByteArray new-size
    new.replace 0 buffer_ 0 offset_
    buffer_ = new

  /**
  Writes the given $data to this buffer at the given index $at.

  The parameters must satisfy 0 <= $at <= ($at + data-size) <= $size, where
    data-size is the `byte-size` of $data.

  See $grow-by, $resize for ways to ensure that the buffer is big enough.
  */
  put --at/int data/Data from/int=0 to/int=data.byte-size:
    if not 0 <= at <= at + (to - from) <= offset_: throw "INVALID_ARGUMENT"
    buffer_.replace at data from to

  /**
  Returns the byte at the given $index.

  The parameter must satisfy 0 <= $index < $size.
  */
  operator[] index/int -> int:
    if not 0 <= index < offset_: throw "OUT_OF_BOUNDS"
    return buffer_[index]

  /**
  Sets the byte at the given $index to the given $value.

  The parameter $index must satisfy 0 <= $index < $size.
  */
  operator[]= index/int value/int -> none:
    if not 0 <= index < offset_: throw "OUT_OF_BOUNDS"
    buffer_[index] = value

  /** Writes a single byte $b. */
  write-byte b/int:
    ensure_ 1
    buffer_[offset_++] = b

  try-write_ data/Data from/int to/int -> int:
    ensure_ to - from
    buffer_.replace offset_ data from to
    offset_ += to - from
    return to - from

  /** See $close. */
  close_:
    if is-growable_ and offset_  != buffer_.size:
      buffer_ = buffer_.copy 0 offset_

  /**
  Provides endian-aware functions to write to this instance.

  The little-endian byte order writes lower-order ("little") bytes first.
    For example, if the target of the write operation is a byte array, then the
    first byte written (at position 0) is the least significant byte of the
    number that is written.

  # Examples
  ```
  import io

  main:
    buffer := io.Buffer
    buffer.little-endian.write-int32 0x12345678
    // The least significant byte 0x78 is at index 0.
    print buffer.bytes  // => #[0x78, 0x56, 0x34, 0x12]

    // The buffer version also supports 'put' operations
    buffer.little-endian.put-int32 --at=0 0x11223344
  ```
  */
  little-endian -> EndianBuffer:
    result := endian_
    if not result or result.byte-order_ != LITTLE-ENDIAN:
      result = EndianBuffer --buffer=this --byte-order=LITTLE-ENDIAN
      endian_ = result
    return (result as EndianBuffer)

  /**
  Provides endian-aware functions to write to this instance.

  The big-endian byte order writes higher-order (big) bytes first.
    For example, if  the target of the write operation is a byte array, then the
    first byte written (at position 0) is the most significant byte of
    the number that is written.

  # Examples
  ```
  import io

  main:
    buffer := io.Buffer
    buffer.big-endian.write-int32 0x12345678
    // The most significant byte 0x12 is at index 0.
    print buffer.bytes  // => #[0x12, 0x34, 0x56, 0x78]

    // The buffer version also supports 'put' operations
    buffer.big-endian.put-int32 --at=0 0x11223344
  ```
  */
  big-endian -> EndianBuffer:
    result := endian_
    if not result or result.byte-order_ != BIG-ENDIAN:
      result = EndianBuffer --buffer=this --byte-order=BIG-ENDIAN
      endian_ = result
    return (result as EndianBuffer)

class EndianBuffer extends EndianWriter:
  buffer_/Buffer

  constructor --buffer/Buffer --byte-order/ByteOrder:
    buffer_ = buffer
    super --writer=buffer --byte-order=byte-order

  /**
  Writes the given byte $value to this buffer at the given index $at.

  This function is an alias for $Buffer.[]=.
  */
  put-int8 --at/int value/int:
    buffer_[at] = value

  /**
  Writes the given unsigned uint8 $value to this buffer at the given index $at.

  This function is an alias for $Buffer.[]= and $put-int8.
  */
  put-uint8 --at/int value/int:
    buffer_[at] = value

  /**
  Writes the given signed int16 $value to this buffer at the given index $at.
  */
  put-int16 --at/int value/int:
    byte-order_.put-int16 cached-byte-array_ 0 value
    buffer_.put --at=at cached-byte-array_ 0 2

  /**
  Writes the given unsigned uint16 $value to this buffer at the given index $at.

  This function is an alias for $put-int16.
  */
  put-uint16 --at/int value/int:
    put-int16 --at=value value

  /**
  Writes the given signed int24 $value to this buffer at the given index $at.
  */
  put-int24 --at/int value/int:
    byte-order_.put-int24 cached-byte-array_ 0 value
    buffer_.put --at=at cached-byte-array_ 0 3

  /**
  Writes the given unsigned uint24 $value to this buffer at the given index $at.

  This function is an alias for $put-int24.
  */
  put-uint24 --at/int value/int:
    put-int24 --at=value value

  /**
  Writes the given signed int32 $value to this buffer at the given index $at. */
  put-int32 --at/int value/int:
    byte-order_.put-int32 cached-byte-array_ 0 value
    buffer_.put --at=at cached-byte-array_ 0 4

  /**
  Writes the given unsigned uint32 $value to this buffer at the given index $at.

  This function is an alias for $put-int32.
  */
  put-uint32 --at/int value/int:
    put-int32 --at=value value

  /** Writes the given int64 $value to this buffer at the given index $at. */
  put-int64 --at/int value/int:
    byte-order_.put-int64 cached-byte-array_ 0 value
    buffer_.put --at=at cached-byte-array_ 0 8

  /** Writes the given float32 $value to this buffer at the given index $at. */
  put-float32 --at/int value/float:
    byte-order_.put-float32 cached-byte-array_ 0 value
    buffer_.put --at=at cached-byte-array_ 0 4

  /** Writes the given float64 $value to this buffer at the given index $at. */
  put-float64 --at/int value/float:
    byte-order_.put-float64 cached-byte-array_ 0 value
    buffer_.put --at=at cached-byte-array_ 0 8

  /**
  Returns the signed 8-bit value at the given position $at.
  */
  int8 --at/int -> int:
    return byte-order_.int8 buffer_.buffer_ at

  /**
  Returns the unsigned 8-bit value at the given position $at.
  */
  uint8 --at/int -> int:
    return byte-order_.uint8 buffer_.buffer_ at

  /**
  Returns the signed 16-bit value at the given position $at.
  */
  int16 --at/int -> int:
    return byte-order_.int16 buffer_.buffer_ at

  /**
  Returns the unsigned 16-bit value at the given position $at.
  */
  uint16 --at/int -> int:
    return byte-order_.uint16 buffer_.buffer_ at

  /**
  Returns the signed 24-bit value at the given position $at.
  */
  int24 --at/int -> int:
    return byte-order_.int24 buffer_.buffer_ at

  /**
  Returns the unsigned 24-bit value at the given position $at.
  */
  uint24 --at/int -> int:
    return byte-order_.uint24 buffer_.buffer_ at

  /**
  Returns the signed 32-bit value at the given position $at.
  */
  int32 --at/int -> int:
    return byte-order_.int32 buffer_.buffer_ at

  /**
  Returns the unsigned 32-bit value at the given position $at.
  */
  uint32 --at/int -> int:
    return byte-order_.uint32 buffer_.buffer_ at

  /**
  Returns the signed 64-bit value at the given position $at.
  */
  int64 --at/int -> int:
    return byte-order_.int64 buffer_.buffer_ at

  /**
  Returns the 32-bit float (single-precision) value at the given position $at.
  */
  float32 --at/int -> float:
    return byte-order_.float32 buffer_.buffer_ at

  /**
  Returns the 64-bit float (double-precision) value at the given position $at.
  */
  float64 --at/int -> float:
    return byte-order_.float64 buffer_.buffer_ at
