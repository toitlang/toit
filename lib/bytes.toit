// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
Utilities to build and use binary data.

The $Buffer class can be used to build up binary data. The collected
  data is then returned in a byte array.

The $Reader class makes a byte array readable, by providing a `read` method.
*/

import io
import reader
import io show BIG-ENDIAN LITTLE-ENDIAN

INITIAL-BUFFER-LENGTH_ ::= 64
MIN-BUFFER-GROWTH_ ::= 64
MAX-INTERNAL-SIZE_ ::= 128

/**
A reader to make byte arrays readable.

Wraps a byte array and makes it readable. Specifically, it
  supports the $read method.
This class also implements the $reader.SizedReader interface
  and thus features the $size method.

Deprecated. Use $io.Reader instead.
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

Deprecated.
*/
interface Producer:
  /** The size of the generated payload. */
  size -> int
  /** Writes the payload into the given $byte-array at the given $offset. */
  write-to byte-array/ByteArray offset/int -> none

/**
A $Producer backed by a byte array.

Instead of creating the payload on demand, this producer is initialized
  with a byte array payload which is then used in the $write-to call.

Deprecated.
*/
class ByteArrayProducer implements Producer:
  byte-array_/ByteArray ::= ?
  from_/int ::= ?
  to_/int ::= ?

  /**
  Constructs a producer.
  The constructed instance returns the range between $from_ and $to_ (exclusive)
    of the $byte-array_ when $write-to is called.
  */
  constructor .byte-array_ .from_=0 .to_=byte-array_.size:

  /** See $Producer.size. */
  size -> int: return to_ - from_

  /** See $Producer.write-to. */
  write-to destination/ByteArray offset/int -> none:
    destination.replace offset byte-array_ from_ to_

/**
A consumer of data.

Due to the operations that take an offset (like $put-int16-big-endian),
  consumers must buffer their data to allow future modifications of it.

Deprecated.
*/
// TODO(4201): missing function `write-from`.
abstract class BufferConsumer:
  /**
  The size of the consumed data.
  This value increases with operations that write into this consumer,
    such as $write-byte or $write. It is reset with $clear, and unchanged
    by operations that take an offset, such as $put-int16-big-endian.
  */
  abstract size -> int
  /**
  Writes the $byte into the consumer.
  This is equivalent to using $write with a one-sized byte array.
  */
  abstract write-byte byte/int -> none
  /**
  Writes the byte of $data at the given $offset.
  The $offset must be valid and the backing store must be able to
    write a byte at this offset. If necessary use $grow before
    doing this operation.
  */
  abstract put-byte offset/int data/int -> none
  /** Writes the given $data into this consumer. */
  abstract write data/io.Data from/int=0 to/int=data.byte-size -> int
  /** Writes the data from the $producer into this consumer. */
  abstract write-producer producer/Producer -> none
  /**
  Grows this consumer by $amount bytes.
  This operation is equivalent to writing an empty byte-array of size $amount.

  The allocated bytes are filled with 0s and can be accessed
    with all methods that take an offset (such as $put-int16-big-endian).

  Further write operations (like $write-byte or $write) append their data
    after the grown bytes.
  */
  abstract grow amount/int -> none

  /**
  Reserves $amount bytes.
  Doesn't change the $size of this buffer, but increases the size of the backing
    store.
  This method is purely for efficiency, so that this consumer doesn't need to
    regrow its internal backing store too often.
  */
  abstract reserve amount/int -> none

  /**
  Closes this buffer.
  It is an error to write to this consumer after a call to $close.
  It is legal to close this consumer multiple times.
  */
  abstract close -> none

  /** Resets the buffer, discarding all accumulated data. */
  abstract clear -> none

  /**
  Writes the 64 bits of $data at the end.
  The backing store is automatically grown by 64 bits.
  */
  abstract write-int64-big-endian data/int -> none
  /**
  Writes the 32 bits of $data at the end.
  The backing store is automatically grown by 32 bits.
  */
  abstract write-int32-big-endian data/int -> none
  /**
  Writes the 16 bits of $data at the end.
  The backing store is automatically grown by 16 bits.
  */
  abstract write-int16-big-endian data/int -> none

  /**
  Writes the 64 bits of $data at the given $offset.
  The $offset must be valid and the backing store must be able to
    write 64 bits at this offset. If necessary use $grow before
    doing this operation.
  */
  abstract put-int64-big-endian offset/int data/int -> none
  /**
  Writes the 32 bits of $data at the given $offset.
  The $offset must be valid and the backing store must be able to
    write 32 bits at this offset. If necessary use $grow before
    doing this operation.
  */
  abstract put-int32-big-endian offset/int data/int -> none
  /**
  Writes the 16 bits of $data at the given $offset.
  The $offset must be valid and the backing store must be able to
    write 16 bits at this offset. If necessary use $grow before
    doing this operation.
  */
  abstract put-int16-big-endian offset/int data/int -> none

  /**
  Writes the 64 bits of $data at the end.
  The backing store is automatically grown by 64 bits.
  */
  abstract write-int64-little-endian data/int -> none
  /**
  Writes the 32 bits of $data at the end.
  The backing store is automatically grown by 32 bits.
  */
  abstract write-int32-little-endian data/int -> none
  /**
  Writes the 16 bits of $data at the end.
  The backing store is automatically grown by 16 bits.
  */
  abstract write-int16-little-endian data/int -> none

  /**
  Writes the 64 bits of $data at the given $offset.
  The $offset must be valid and the backing store must be able to
    write 64 bits at this offset. If necessary use $grow before
    doing this operation.
  */
  abstract put-int64-little-endian offset/int data/int -> none
  /**
  Writes the 32 bits of $data at the given $offset.
  The $offset must be valid and the backing store must be able to
    write 32 bits at this offset. If necessary use $grow before
    doing this operation.
  */
  abstract put-int32-little-endian offset/int data/int -> none
  /**
  Writes the 16 bits of $data at the given $offset.
  The $offset must be valid and the backing store must be able to
    write 16 bits at this offset. If necessary use $grow before
    doing this operation.
  */
  abstract put-int16-little-endian offset/int data/int -> none

/**
A consumer that counts the number of written bytes.

This class is used when writing happens in two phases:
- counting of bytes.
- writing into a buffer of the correct size.

In this scenario data is processed twice, but the resulting
  buffer is allocated with the right size from the beginning.

Deprecated.
*/
class BufferSizeCounter extends BufferConsumer:  // @no-warn
  /** See $BufferConsumer.size. */
  size := 0
  /** See $BufferConsumer.write-byte. */
  put-byte offset/int byte/int -> none:
  /** See $BufferConsumer.write-byte. */
  write-byte byte/int -> none: size++
  /** See $BufferConsumer.write. */
  write data/io.Data from/int=0 to/int=data.byte-size -> int:
    size += to - from
    return to - from
  /**
  See $BufferConsumer.write-producer.

  This operation only requests the size of the $producer.
  */
  write-producer producer/Producer -> none: size += producer.size
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
  /** See $BufferConsumer.write-int64-big-endian. */
  write-int64-big-endian data/int -> none:
    size += 8
  /** See $BufferConsumer.write-int32-big-endian. */
  write-int32-big-endian data/int -> none:
    size += 4
  /** See $BufferConsumer.write-int16-big-endian. */
  write-int16-big-endian data/int -> none:
    size += 2
  /** See $BufferConsumer.put-int64-big-endian. */
  put-int64-big-endian offset/int data/int -> none:
  /** See $BufferConsumer.put-int32-big-endian. */
  put-int32-big-endian offset/int data/int -> none:
  /** See $BufferConsumer.put-int16-big-endian. */
  put-int16-big-endian offset/int data/int -> none:
  /** See $BufferConsumer.write-int64-little-endian. */
  write-int64-little-endian data/int -> none:
    size += 8
  /** See $BufferConsumer.write-int32-little-endian. */
  write-int32-little-endian data/int -> none:
    size += 4
  /** See $BufferConsumer.write-int16-little-endian. */
  write-int16-little-endian data/int -> none:
    size += 2
  /** See $BufferConsumer.put-int64-little-endian. */
  put-int64-little-endian offset/int data/int -> none:
  /** See $BufferConsumer.put-int32-little-endian. */
  put-int32-little-endian offset/int data/int -> none:
  /** See $BufferConsumer.put-int16-little-endian. */
  put-int16-little-endian offset/int data/int -> none:

/**
A buffer that can be used to build byte data.

Deprecated. Use $io.Buffer instead.

# Aliases
- `BytesBuilder`: Dart
- `ByteArrayOutputStream`: Java
*/
class Buffer extends BufferConsumer:
  init-size_/int
  buffer_ /ByteArray := ?
  offset_ := 0

  /**
  Constructs a new buffer.
  The backing byte array is allocated with a default size and will
    grow if needed.
  */
  constructor:  // @no-warn
    // We copy the code of the 'with-initial-size' constructor, so we don't get
    // a deprecation warning.
    init-size_ = INITIAL-BUFFER-LENGTH_
    buffer_ = init-size_ > MAX-INTERNAL-SIZE_ ? (ByteArray.external init-size_) : (ByteArray init-size_)

  /**
  Constructs a new buffer with the given $init-size_.
  If the $init-size_ isn't big enough, the buffer grows when necessary.
  */
  constructor.with-initial-size .init-size_/int:  // @no-warn
    buffer_ = init-size_ > MAX-INTERNAL-SIZE_ ? (ByteArray.external init-size_) : (ByteArray init-size_)

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
  Converts the consumed data to a string.
  This operation is equivalent to `take.to-string`.
  */
  to-string -> string:
    return buffer_.to-string 0 offset_

  /** See $BufferConsumer.write-byte. */
  write-byte byte/int -> none:
    ensure_ 1
    buffer_[offset_++] = byte

  /** See $BufferConsumer.put-byte. */
  put-byte offset/int byte/int -> none:
    buffer_[offset] = byte

  /** Writes all data from the reader $r into this buffer. */
  write-from r/reader.Reader:
    if r is reader.SizedReader:
      ensure_ (r as reader.SizedReader).size
    while data := r.read: write data

  /** See $BufferConsumer.write. */
  write data/io.Data from/int=0 to/int=data.byte-size -> int:
    count := to - from
    ensure_ count
    buffer_.replace offset_ data from to
    offset_ += count
    return count

  /** See $BufferConsumer.write-producer. */
  write-producer producer/Producer -> none:
    ensure_ producer.size
    producer.write-to buffer_ offset_
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
    if buffer_.size > init-size_ * 2: buffer_ = ByteArray init-size_

  /** See $BufferConsumer.write-int16-big-endian. */
  write-int16-big-endian data/int -> none:
    ensure_ 2
    put-int16-big-endian offset_ data
    offset_ += 2

  /** See $BufferConsumer.write-int32-big-endian. */
  write-int32-big-endian data/int -> none:
    ensure_ 4
    put-int32-big-endian offset_ data
    offset_ += 4

  /** See $BufferConsumer.write-int64-big-endian. */
  write-int64-big-endian data/int -> none:
    ensure_ 8
    put-int64-big-endian offset_ data
    offset_ += 8

  /** See $BufferConsumer.put-int16-big-endian. */
  put-int16-big-endian offset/int data/int -> none:
    BIG-ENDIAN.put-int16 buffer_ offset data

  /** See $BufferConsumer.put-int32-big-endian. */
  put-int32-big-endian offset/int data/int -> none:
    BIG-ENDIAN.put-int32 buffer_ offset data

  /** See $BufferConsumer.put-int64-big-endian. */
  put-int64-big-endian offset/int data/int -> none:
    BIG-ENDIAN.put-int64 buffer_ offset data

  /** See $BufferConsumer.write-int16-little-endian. */
  write-int16-little-endian data/int -> none:
    ensure_ 2
    put-int16-little-endian offset_ data
    offset_ += 2

  /** See $BufferConsumer.write-int32-little-endian. */
  write-int32-little-endian data/int -> none:
    ensure_ 4
    put-int32-little-endian offset_ data
    offset_ += 4

  /** See $BufferConsumer.write-int64-little-endian. */
  write-int64-little-endian data/int -> none:
    ensure_ 8
    put-int64-little-endian offset_ data
    offset_ += 8

  /** See $BufferConsumer.put-int16-little-endian. */
  put-int16-little-endian offset/int data/int -> none:
    LITTLE-ENDIAN.put-int16 buffer_ offset data

  /** See $BufferConsumer.put-int32-little-endian. */
  put-int32-little-endian offset/int data/int -> none:
    LITTLE-ENDIAN.put-int32 buffer_ offset data

  /** See $BufferConsumer.put-int64-little-endian. */
  put-int64-little-endian offset/int data/int -> none:
    LITTLE-ENDIAN.put-int64 buffer_ offset data

  ensure_ size:
    new-minimum-size := offset_ + size
    if new-minimum-size <= buffer_.size: return

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

    assert: offset_ + size  <= new-size

    new := ByteArray new-size
    new.replace 0 buffer_ 0 offset_
    buffer_ = new
