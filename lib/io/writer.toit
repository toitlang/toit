// Copyright (C) 2024 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .byte-order
import .data
import .reader
import writer as old-writer

/**
A consumer of bytes.

# Inheritance
The method $try-write_ must be implemented by subclasses.
The method $flush may be implemented by subclasses. The default implementation does nothing.
*/
abstract class Writer:
  is-closed_/bool := false
  endian_/EndianWriter? := null
  byte-cache_/ByteArray? := null
  processed_/int := 0

  constructor:

  /**
  Constructor to convert old-style writers to this writer.

  The $writer must either be a $old-writer.Writer or a class with a `write` function
    that returns the number of bytes written.
  */
  constructor.adapt writer:
    return WriterAdapter_ writer

  /**
  The amount of bytes that have been written to this writer so far.
  */
  processed -> int:
    return processed_

  /**
  Writes the given $data to this writer.

  Returns the amount of bytes written (to - from).

  If the writer can't write all the data at once tries again until all of the data is
    written. This method is blocking.
  */
  write data/Data from/int=0 to/int=data.byte-size --flush/bool=false -> int:
    pos := from
    while not is-closed_:
      pos += try-write data pos to
      if pos >= to:
        if flush: this.flush
        return (to - from)
      wait-for-more-room_
    assert: is-closed_
    throw "WRITER_CLOSED"

  /**
  Writes a single byte.
  */
  write-byte value/int --flush/bool=false -> none:
    cache := byte-cache_
    if not cache:
      cache = ByteArray 1
      byte-cache_ = cache
    cache[0] = value
    // Protect against concurrent writes.
    // It's probably a mistake to write concurrently, but it's pretty easy to guard
    // the cache against it.
    byte-cache_ = null
    write cache --flush=flush
    byte-cache_ = cache

  /**
  Writes all data that is provided by the given $reader.
  */
  write-from reader/Reader --flush/bool=false -> none:
    if is-closed_: throw "WRITER_CLOSED"
    while data := reader.read:
      write data
    if flush: this.flush

  /**
  Flushes any buffered data to the underlying resource.

  Often, one can just use the `--flush` flag of the $write, $write-byte or $write-from
    functions instead.

  # Inheritance
  This method may be overwritten by subclasses. The default implementation does nothing.
  */
  flush -> none:
    // Do nothing.

  /**
  Tries to write the given $data to this writer.
  If the writer can't write all the data at once, it writes as much as possible.
  If the writer is closed while writing, throws, or returns the number of bytes written.
  Otherwise always returns the number of bytes written.

  # Inheritance
  Implementations are not required to check whether the writer is closed.

  If the writer is closed while this operation is in progress, the writer may throw
    an exception or return a number smaller than $to - $from.
  */
  try-write data/Data from/int=0 to/int=data.byte-size -> int:
    if is-closed_: throw "WRITER_CLOSED"
    written := try-write_ data from to
    processed_ += written
    return written

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
    buffer := io.Buffer  // A writer.
    buffer.little-endian.write-int32 0x12345678
    // The least significant byte 0x78 is at index 0.
    print buffer.bytes  // => #[0x78, 0x56, 0x34, 0x12]
  ```
  */
  little-endian -> EndianWriter:
    if not endian_ or endian_.byte-order_ != LITTLE_ENDIAN:
      endian_ = EndianWriter --writer=this --byte-order=LITTLE_ENDIAN
    return endian_

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
  ```
  */
  big-endian -> EndianWriter:
    if not endian_ or endian_.byte-order_ != BIG_ENDIAN:
      endian_ = EndianWriter --writer=this --byte-order=BIG_ENDIAN
    return endian_

  /**
  Tries to write the given $data to this writer.
  If the writer can't write all the data at once, it writes as much as possible.
  Always returns the number of bytes written.

  # Inheritance
  Implementations are not required to check whether the writer is closed.

  If the writer is closed while this operation is in progress, the writer may throw
    an exception or return a number smaller than $to - $from.
  */
  // This is a protected method. It should not be "private".
  abstract try-write_ data/Data from/int to/int -> int

  /**
  Closes this writer.

  Sets the internal boolean to 'closed'.
  Further writes throw an exception.

  Deprecated. Use $mark-closed_ instead.
  */
  // This is a protected method. It should not be "private".
  close-writer_:
    is-closed_ = true

  /**
  Marks this writer as closed.

  Sets the internal boolean to 'closed'.
  Further writes throw an exception.
  */
  // This is a protected method. It should not be "private".
  mark-closed_:
    is-closed_ = true

  /**
  Gives the resource the opportunity to make room for more data.

  # Inheritance
  By default this function just ($yield)s, but subclasses may have better
    ways of detecting that buffers are emptied.
  */
  // This is a protected method. It should not be "private".
  wait-for-more-room_ -> none:
    yield

abstract class CloseableWriter extends Writer:
  /**
  Closes this writer.

  After this method has been called, no more data can be written to this writer.
  This method may be called multiple times.
  */
  close:
    if is-closed_: return
    try:
      close_
    finally:
      mark-closed_

  /** Whether this writer is closed. */
  is-closed -> bool:
    return is-closed_

  /**
  See $close.

  # Inheritance
  Implementations should close down the underlying resource.
  If the writer is in the process of writing data, it may throw an exception, or
    abort the write, returning the number of bytes that have been written so far.
  */
  // This is a protected method. It should not be "private".
  abstract close_ -> none

abstract mixin OutMixin:
  _out_/Out_? := null

  out -> Writer:
    result := _out_
    if not result:
      result = Out_ this
      _out_ = result
    return result

  /**
  Closes the writer if it exists.

  The $out $Writer doesn't have a 'close' method. However, we can set
    the internal boolean to closed, so that further writes throw an exception, or
    that existing writes are aborted.

  Any existing write needs to be aborted by the caller of this method.
    The $try-write_ should either throw or return the number of bytes that have been
    written so far. See $CloseableWriter.close_.

  Deprecated. Use $mark-writer-closed_ instead.
  */
  // This is a protected method. It should not be "private".
  close-writer_ -> none:
    if _out_: _out_.mark-closed_

  /**
  Marks the writer as closed.

  The $out $Writer doesn't have a 'close' method. It only sets the
    the internal boolean to closed, so that further writes throw.

  Any existing write needs to be aborted by the caller of this method.
    The $try-write_ should either throw or return the number of bytes that have been
    written so far. See $CloseableWriter.close_.
  */
  // This is a protected method. It should not be "private".
  mark-writer-closed_ -> none:
    if _out_: _out_.mark-closed_

  /**
  Writes the given $data to this writer.

  Returns the number of bytes written.

  # Inheritance
  See $Writer.try-write_.
  */
  // This is a protected method. It should not be "private".
  abstract try-write_ data/Data from/int to/int -> int

abstract mixin CloseableOutMixin:
  _out_/CloseableOut_? := null

  out -> CloseableWriter:
    if not _out_: _out_ = CloseableOut_ this
    return _out_

  /**
  Marks the writer as closed.

  The $out $Writer doesn't have a 'close' method. It only sets the
    the internal boolean to closed, so that further writes throw.

  Any existing write needs to be aborted by the caller of this method.
    The $try-write_ should either throw or return the number of bytes that have been
    written so far. See $CloseableWriter.close_.
  */
  // This is a protected method. It should not be "private".
  mark-writer-closed_ -> none:
    if _out_: _out_.mark-closed_

  /**
  Writes the given $data to this writer.

  Returns the number of bytes written.

  # Inheritance
  See $Writer.try-write_.
  */
  // This is a protected method. It should not be "private".
  abstract try-write_ data/Data from/int to/int -> int

  /**
  Closes this writer.

  # Inheritance
  See $CloseableWriter.close_.
  */
  // This is a protected method. It should not be "private".
  abstract close-writer_ -> none


class Out_ extends Writer:
  mixin_/OutMixin

  constructor .mixin_:

  try-write_ data/Data from/int to/int -> int:
    return mixin_.try-write_ data from to

class CloseableOut_ extends CloseableWriter:
  mixin_/CloseableOutMixin

  constructor .mixin_:

  try-write_ data/Data from/int to/int -> int:
    return mixin_.try-write_ data from to

  close_ -> none:
    mixin_.close-writer_

class EndianWriter:
  writer_/Writer
  byte-order_/ByteOrder
  cached-byte-array_/ByteArray ::= ByteArray 8

  constructor --writer/Writer --byte-order/ByteOrder:
    writer_ = writer
    byte-order_ = byte-order

  /** Writes a singed 8-bit integer. */
  write-int8 value/int -> none:
    cached-byte-array_[0] = value
    writer_.write cached-byte-array_ 0 1

  /** Writes an unsigned 8-bit integer. */
  write-uint8 value/int -> none:
    cached-byte-array_[0] = value
    writer_.write cached-byte-array_ 0 1

  /** Writes a signed 16-bit integer, using the endiannes of this instance. */
  write-int16 value/int -> none:
    byte-order_.put-int16 cached-byte-array_ 0 value
    writer_.write cached-byte-array_ 0 2

  /** Writes an unsigned 16-bit integer, using the endiannes of this instance. */
  write-uint16 value/int -> none:
    byte-order_.put-uint16 cached-byte-array_ 0 value
    writer_.write cached-byte-array_ 0 2

  /** Writes a signed 24-bit integer, using the endiannes of this instance. */
  write-int24 value/int -> none:
    byte-order_.put-int24 cached-byte-array_ 0 value
    writer_.write cached-byte-array_ 0 3

  /** Writes an unsigned 24-bit integer, using the endiannes of this instance. */
  write-uint24 value/int -> none:
    byte-order_.put-uint24 cached-byte-array_ 0 value
    writer_.write cached-byte-array_ 0 3

  /** Writes a signed 32-bit integer, using the endiannes of this instance. */
  write-int32 value/int -> none:
    byte-order_.put-int32 cached-byte-array_ 0 value
    writer_.write cached-byte-array_ 0 4

  /** Writes an unsigned 32-bit integer, using the endiannes of this instance. */
  write-uint32 value/int -> none:
    byte-order_.put-uint32 cached-byte-array_ 0 value
    writer_.write cached-byte-array_ 0 4

  /** Writes a signed 64-bit integer, using the endiannes of this instance. */
  write-int64 data/int -> none:
    byte-order_.put-int64 cached-byte-array_ 0 data
    writer_.write cached-byte-array_ 0 8

  /** Writes a 32-bit floating-point number, using the endianness of this instance. */
  write-float32 data/float -> none:
    byte-order_.put-float32 cached-byte-array_ 0 data
    writer_.write cached-byte-array_ 0 4

  /** Writes a 64-bit floating-point number, using the endianness of this instance. */
  write-float64 data/float -> none:
    byte-order_.put-float64 cached-byte-array_ 0 data
    writer_.write cached-byte-array_ 0 8

/**
Adapter to use an old-style writer as $Writer.
*/
class WriterAdapter_ extends Writer:
  w_/any

  constructor .w_:

  try-write_ data/Data from/int to/int -> int:
    return w_.write data from to
