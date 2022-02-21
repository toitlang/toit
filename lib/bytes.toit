// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
Utilities to build and use binary data.

The $Buffer class can be used to build up binary data. The collected
  data is then returned in a byte array.

The $Reader class makes a byte array readable, by providing a `read` method.
*/

import binary show BIG_ENDIAN
import reader

INITIAL_BUFFER_LENGTH_ ::= 64
MIN_BUFFER_GROWTH_ ::= 64
MAX_INTERNAL_SIZE_ ::= 128

/**
A reader to make byte arrays readable.

Wraps a byte array and makes it readable. Specifically, it
  supports the $read method.
This class also implements the $reader.SizedReader interface
  and thus features the $size method.
*/
class Reader implements reader.SizedReader:
  data_/ByteArray? := ?

  /**
  Constructs a new Reader from the given byte array.

  The byte array is wrapped and not copied. As such, it should not
    be changed while the reader is used.
  */
  constructor .data_:

  /**
  Reads more data.
  Returns null when no data is left.

  This implementation simply returns the complete byte array the
    first time this method is called and then null for every
    following call.
  */
  read -> ByteArray?:
    d := data_
    data_ = null
    return d

  /**
  The initial size of this reader.
  Must only be called before starting to $read.
  */
  size -> int: return data_.size

/**
Producer that can produce a fixed size payload of data, on demand.
Can be used to generate data for serialization, when the amount of data is
  known ahead of time.
*/
interface Producer:
  /** The size of the generated payload. */
  size -> int
  /** Writes the payload into the given $byte_array at the given $offset. */
  write_to byte_array/ByteArray offset/int -> none

/**
A $Producer backed by a byte array.

Instead of creating the payload on demand, this producer is initialized
  with a byte array payload which is then used in the $write_to call.
*/
class ByteArrayProducer implements Producer:
  byte_array_/ByteArray ::= ?
  from_/int ::= ?
  to_/int ::= ?

  /**
  Constructs a producer.
  The constructed instance returns the range between $from_ and $to_ (exclusive)
    of the $byte_array_ when $write_to is called.
  */
  constructor .byte_array_ .from_=0 .to_=byte_array_.size:

  /** See $Producer.size. */
  size -> int: return to_ - from_

  /** See $Producer.write_to. */
  write_to destination/ByetArray offset/int -> none:
    destination.replace offset byte_array_ from_ to_

/**
A consumer of data.

Due to the operations that take an offset (like $put_int16_big_endian),
  consumers must buffer their data to allow future modifications of it.
*/
// TODO(4201): missing function `write_from`.
interface BufferConsumer:
  /**
  The size of the consumed data.
  This value increases with operations that write into this consumer,
    such as $put_byte or $write. It is reset with $clear, and unchanged
    by operations that take an offset, such as $put_int16_big_endian.
  */
  size -> int
  /**
  Writes the $byte into the consumer.
  This is equivalent to using $write with a one-sized byte array.
  */
  put_byte byte/int -> none
  /** Writes the given $data into this consumer. */
  write data from/int=0 to/int=data.size -> int
  /** Writes the data from the $producer into this consumer. */
  put_producer producer/Producer -> none
  /**
  Grows this consumer by $amount bytes.
  This operation is equivalent to writing an empty byte-array of size $amount.

  The allocated bytes are filled with 0s and can be accessed
    with all methods that take an offset (such as $put_int16_big_endian).

  Further write operations (like $put_byte or $write) append their data
    after the grown bytes.
  */
  grow amount/int -> none

  /**
  Reserves $amount bytes.
  Doesn't change the $size of this buffer, but increases the size of the backing
    store.
  This method is purely for efficiency, so that this consumer doesn't need to
    regrow its internal backing store too often.
  */
  reserve amount/int -> none

  /**
  Closes this buffer.
  It is an error to write to this consumer after a call to $close.
  It is legal to close this consumer multiple times.
  */
  close -> none

  /** Resets the buffer, discarding all accumulated data. */
  clear -> none

  /**
  Writes the 64 bits of $data at the given $offset.
  The $offset must be valid and the backing store must be able to
    write 64 bits at this offset. If necessary use $grow before
    doing this operation.
  */
  put_int64_big_endian offset/int data/int -> none
  /**
  Writes the 32 bits of $data at the given $offset.
  The $offset must be valid and the backing store must be able to
    write 32 bits at this offset. If necessary use $grow before
    doing this operation.
  */
  put_int32_big_endian offset/int data/int -> none
  /**
  Writes the 16 bits of $data at the given $offset.
  The $offset must be valid and the backing store must be able to
    write 16 bits at this offset. If necessary use $grow before
    doing this operation.
  */
  put_int16_big_endian offset/int data/int -> none

/**
A consumer that counts the number of written bytes.

This class is used when writing happens in two phases:
- counting of bytes.
- writing into a buffer of the correct size.

In this scenario data is processed twice, but the resulting
  buffer is allocated with the right size from the beginning.
*/
class BufferSizeCounter implements BufferConsumer:
  /** See $BufferConsumer.size. */
  size := 0
  /** See $BufferConsumer.put_byte. */
  put_byte byte/int -> none: size++
  /** See $BufferConsumer.write. */
  write data from/int=0 to/int=data.size -> int:
    size += to - from
    return to - from
  /**
  See $BufferConsumer.put_producer.

  This operation only requests the size of the $producer.
  */
  put_producer producer/Producer -> none: size += producer.size
  /** See $BufferConsumer.grow. */
  grow amount/int -> none: size +=  amount
  /** See $BufferConsumer.reserve. */
  reserve amount/int -> none:
  /** See $BufferConsumer.close. */
  close -> none:
  /**
  See $BufferConsumer.clear.
  This operation resets the size to 0. This consumer does *not* remember the
    size that was seen so far.
  */
  clear -> none: size = 0
  /** See $BufferConsumer.put_int64_big_endian. */
  put_int64_big_endian offset/int data/int -> none:
  /** See $BufferConsumer.put_int32_big_endian. */
  put_int32_big_endian offset/int data/int -> none:
  /** See $BufferConsumer.put_int16_big_endian. */
  put_int16_big_endian offset/int data/int -> none:

/**
A buffer that can be used to build byte data.

# Aliases
- `BytesBuilder`: Dart
- `ByteArrayOutputStream`: Java
*/
class Buffer implements BufferConsumer:
  init_size_/int
  buffer_ /ByteArray := ?
  offset_ := 0

  /**
  Constructs a new buffer.
  The backing byte array is allocated with a default size and will
    grow if needed.
  */
  constructor:
    return Buffer.with_initial_size INITIAL_BUFFER_LENGTH_

  /**
  Constructs a new buffer with the given $init_size_.
  If the $init_size_ isn't big enough, the buffer grows when necessary.
  */
  constructor.with_initial_size .init_size_/int:
    buffer_ = init_size_ > MAX_INTERNAL_SIZE_ ? (ByteArray_.external_ init_size_) : (ByteArray init_size_)

  /** See $BufferConsumer.size. */
  size -> int:
    return offset_

  /**
  The backing byte array.
  The buffer might have a size bigger than $size.
  */
  buffer -> ByteArray:
    return buffer_

  /**
  Return a view of the buffer, limited to 0..$size.
  */
  bytes -> ByteArray:
    return buffer_[0..size]

  /**
  Deprecated. Use $bytes.
  */
  take -> ByteArray:
    if offset_ == buffer_.size: return buffer_
    return buffer_.copy 0 offset_

  /**
  Converts the consumed data to a string.
  This operation is equivalent to `take.to_string`.
  */
  to_string -> string:
    return buffer_.to_string 0 offset_

  /** See $BufferConsumer.put_byte. */
  put_byte byte/int -> none:
    ensure_ 1
    buffer_[offset_++] = byte

  /** Writes all data from the reader $r into this buffer. */
  write_from r/reader.Reader:
    if r is reader.SizedReader:
      ensure_ (r as reader.SizedReader).size
    while data := r.read: write data

  /** See $BufferConsumer.write. */
  write data from/int=0 to/int=data.size -> int:
    count := to - from
    ensure_ count
    buffer_.replace offset_ data from to
    offset_ += count
    return count

  /** See $BufferConsumer.put_producer. */
  put_producer producer/Producer -> none:
    ensure_ producer.size
    producer.write_to buffer_ offset_
    offset_ += producer.size

  /** See $BufferConsumer.grow. */
  grow amount/int -> none:
    ensure_ amount
    // Be sure to clear the data.
    buffer_.fill --from=offset_ --to=offset_ + amount 0
    offset_ += amount

  /** See $BufferConsumer.reserve. */
  reserve amount/int -> none:
    ensure_ amount

  /**
  See $BufferConsumer.close.

  Trims the backing store to avoid waste.
  */
  close -> none:
    if offset_ != buffer_.size:
      buffer_ = buffer_.copy 0 offset_

  /** See $BufferConsumer.clear. */
  clear -> none:
    offset_ = 0
    // Replace the byte-array, if it grew out of init size.
    if buffer_.size > init_size_ * 2: buffer_ = ByteArray init_size_

  /** See $BufferConsumer.put_int16_big_endian. */
  put_int16_big_endian offset/int data/int -> none:
    BIG_ENDIAN.put_int16 buffer_ offset data

  /** See $BufferConsumer.put_int32_big_endian. */
  put_int32_big_endian offset/int data/int -> none:
    BIG_ENDIAN.put_int32 buffer_ offset data

  /** See $BufferConsumer.put_int64_big_endian. */
  put_int64_big_endian offset/int data/int -> none:
    BIG_ENDIAN.put_int64 buffer_ offset data

  ensure_ size:
    new_minimum_size := offset_ + size
    if new_minimum_size <= buffer_.size: return

    // If we are ensuring a very big size, then make the buffer fit exactly.
    // This is good for ubjson encodings that end with a large byte array,
    // because there is no waste.  Otherwise grow by at least a factor (of 1.5)
    // to avoid quadratic running times.
    new_size := max
      buffer_.size +
        max
          buffer_.size >> 1
          MIN_BUFFER_GROWTH_
      new_minimum_size

    assert: offset_ + size  <= new_size

    new := ByteArray new_size
    new.replace 0 buffer_ 0 offset_
    buffer_ = new
