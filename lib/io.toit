// Copyright (C) 2023 Toitware ApS. All rights reserved.

import binary
import reader as old-reader
import writer as old-writer

/**
A producer of bytes.

The most important implementations of this interface are
  $ByteArray and $string. However, any data structure that can be
  used as byte-source should implement this interface.

Since $Data objects can be instances of $ByteArray it is sometimes
  judicious to test if the given instance is already of class `ByteArray` before
  invoking $write-to-byte-array.
*/
interface Data:
  /** The amount of bytes that can be produced. */
  byte-size -> int

  /**
  Returns a slice of this data.
  */
  byte-slice from/int to/int -> Data

  /** Returns the byte at the given index. */
  byte-at index/int -> int

  /**
  Copies the bytes in the range $from-$to into the given $byte-array at the
    position $at.

  The parameter $from and the parameter $to must satisfy: 0 <= $from <= $to <= $byte-size.
  The parameter $at must satisfy 0 <= $at <= `bytes-size` where `bytes-size` is the
    size of the given $byte-array. It may only be equal to the size if $from == $to.

  # Inheritance
  Implementations are not required to check whether $at satisfies the required properties.
  Since writes to the given $byte-array are checked by the target, errors would automatically
    be reported then. This also means that the user might not get an error message if $at
    is not in bounds, but $from == $to. This is acceptable behavior.
  */
  write-to-byte-array byte-array/ByteArray --at/int from/int to/int -> none


/**
A consumer of bytes.
*/
abstract class Writer:
  is-closed_/bool := false

  constructor:

  /**
  Constructor to convert old-style writers to this writer.

  The $writer must either be a $old-writer.Writer or a class with a `write` function
    that returns the number of bytes written.
  */
  constructor.adapt writer:
    return WriterAdapter_ writer

  /**
  Writes the given $data to this writer.

  If the writer can't write all the data at once tries again until all of the data is
    written. This method is blocking.
  */
  write data/Data from/int=0 to/int=data.byte-size -> none:
    while not is-closed_:
      from += try-write data from to
      if from >= to: return
      yield
    assert: is-closed_
    throw "WRITER_CLOSED"

  /**
  Writes all data that is provided by the given $reader.
  */
  write-from reader/Reader -> none:
    if is-closed_: throw "WRITER_CLOSED"
    while data := reader.read:
      write data

  /**
  Tries to write the given $data to this writer.
  If the writer can't write all the data at once, it writes as much as possible.
  Always returns the number of bytes written.

  # Inheritance
  Implementations are not required to check whether the writer is closed.

  If the writer is closed while this operation is in progress, the writer may throw
    an exception or return a number smaller than $to - $from.
  */
  try-write data/Data from/int=0 to/int=data.byte-size -> int:
    if is-closed_: throw "WRITER_CLOSED"
    return try-write_ data from to

  /**
  Closes this writer.

  After this method has been called, no more data can be written to this writer.
  This method may be called multiple times.
  */
  close:
    if is-closed_: return
    close_
    is-closed_ = true

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
  See $close.

  # Inheritance
  Implementations should close down the underlying resource.
  If the writer is in the process of writing data, it may throw an exception, or
    abort the write, returning the number of bytes that have been written so far.
  */
  // This is a protected method. It should not be "private".
  abstract close_ -> none


/**
A source of bytes.
*/
abstract class Reader implements old-reader.Reader:
  static UNEXPECTED-END-OF-READER ::= "UNEXPECTED_END_OF_READER"

  is-closed_/bool := false

  // A queue of byte arrays that have arrived but haven't been processed yet.
  buffered_/Deque? := null

  /**
  The position in the first byte array.
  All data before this position has been consumed.
  */
  first-bytes-position_ := 0

  constructor:
  constructor data/ByteArray:
    return ByteArrayReader_ data

  constructor.adapt r/old-reader.Reader:
    return ReaderAdapter_ r

  /**
  Reads a chunk of data.

  Returns null if no more data is left.

  If data has been buffered returns the buffered data first.
  Otherwise attempts to read new data from the resource.

  If $max-size is given, returns at most $max-size bytes.
  */
  read --max-size/int?=null -> ByteArray?:
    is-empty := not buffered_ or buffered_.is-empty
    if is-empty and is-closed_: return null

    if max-size:
      if is-empty:
        size := more_
        if not size: return null
      bytes := buffered_.first
      if bytes.size - first-bytes-position_ > max-size:
        result := bytes[first-bytes-position_ .. first-bytes-position_ + max-size]
        first-bytes-position_ += max-size
        return result
      result := bytes[first-bytes-position_..]
      first-bytes-position_ = 0
      buffered_.remove-first
      return result

    if is-empty:
      if is-closed_: return null
      return consume_
    bytes := buffered_.remove-first
    result := bytes[first-bytes-position_..]
    first-bytes-position_ = 0
    return result

  /**
  Closes this reader.

  Reading from the reader after this method has been called is allowed and
    returns the buffered data and then null.

  If $clear-buffered is true, then the buffered data is dropped and reading
    from the reader after this method has been called returns null.
  */
  close --clear-buffered/bool=false -> none:
    if clear-buffered: clear
    if is-closed_: return
    close_
    is-closed_ = true

  /**
  Clears the buffered data.
  */
  clear -> none:
    buffered_ = null
    first-bytes-position_ = 0

  /**
  Ensures that $requested bytes are available.

  If this is not possible, invokes $on-end.
  */
  ensure_ requested/int [on-end] -> none:
    size := buffered-size
    while size < requested:
      new-packet-size := more_
      if not new-packet-size: on_end.call
      size += new-packet-size

  /**
  Gets more data from the reader.
  Returns null if the the reader has been closed. This can be due to
    closing on our side or on the other end.
  Otherwise returns the number of bytes read.
  */
  more_ -> int?:
    data := null
    while true:
      data = consume_
      if not data: return null
      if data.size != 0: break
      yield
    buffer_ data
    return data.size

  /**
  Buffers the given $data.
  */
  buffer_ data/ByteArray -> none:
    if not buffered_: buffered_ = Deque
    buffered_.add data
    if buffered_.size == 1: first-bytes-position_ = 0

  /**
  Ensures that at least $requested bytes are buffered.

  If this is not possible, throws $UNEXPECTED-END-OF-READER.
  */
  ensure-buffered requested/int -> none:
    ensure_ requested: throw UNEXPECTED-END-OF-READER

  /**
  Attempts to ensure that at least $requested bytes are buffered.

  If this is not possible, returns false.
  */
  try-ensure-buffered requested/int -> bool:
    ensure_ requested: return false
    return true

  /**
  Returns whether $n bytes are available.

  If necessary reads more data and buffers it.
  */
  can-ensure n/int -> bool:
    ensure_ n: return false
    return true

  /**
  Buffers all the remaining data of this reader.

  Use $buffered-size to determine how much data was buffered.
  Use $read-bytes to read the buffered data.
  */
  buffer-all -> none:
    while more_: null

  /**
  Returns how much data is buffered.
  */
  buffered-size -> int:
    if not buffered_: return 0
    sum := 0
    start := first-bytes-position_
    buffered_.do:
      sum += it.size - start
      start = 0
    return sum

  /**
  Skip over the next $n bytes.

  If this is not possible, throws $UNEXPECTED-END-OF-READER.
  */
  skip n/int -> none:
    while n > 0:
      if not buffered_ or buffered_.is-empty:
        if not more_:
          throw UNEXPECTED-END-OF-READER

      size := buffered_.first.size - first-bytes-position_
      if n < size:
        first-bytes-position_ += n
        return

      n -= size
      buffered_.remove-first
      first-bytes-position_ = 0

  /**
  Gets the $n th byte from our current position.
  Does not consume the data, but caches it in this instance.

  If enough data is already cached simply returns the byte without
    requesting more data.

  See $read-byte.
  */
  peek-byte n/int -> int:
    ensure-buffered n + 1
    n += first-bytes-position_
    buffered_.do:
      size := it.size
      if n < size: return it[n]
      n -= size
    unreachable

  /**
  Reads a single byte.

  Throws $UNEXPECTED-END-OF-READER if no more data is available.

  See $peek-byte.
  */
  read-byte -> int:
    b := peek_byte 0
    skip 1
    return b

  /**
  Gets the $n next bytes.
  Does not consume the data and caches it in this instance.

  If enough data is already cached simply returns the bytes without
    requesting more data.

  See $read-bytes.
  */
  peek-bytes n/int -> ByteArray:
    ensure-buffered n
    result := ByteArray n
    offset := 0
    start := first-bytes-position_
    buffered_.do:
      size := it.size - start
      if offset + size > n: size = n - offset
      result.replace offset it start start+size
      offset += size
      if offset == n: return result
      start = 0
    return #[]

  /**
  Reads the rest of the data and returns it.
  */
  read-all -> ByteArray?:
    buffer-all
    return read-bytes buffered-size

  /**
  Drains the reader without buffering or returning the data.
  */
  drain -> none:
    clear
    while consume_: null // Do nothing.

  /**
  Reads $n bytes.

  Throws $UNEXPECTED-END-OF-READER if not enough data is available.

  See $peek-bytes.
  */
  read-bytes n -> ByteArray:
    bytes := peek_bytes n
    skip n
    return bytes

  /**
  Peeks at the next $n bytes and returns them as string.

  Does not consume the data, but caches it in this instance.

  The bytes must be valid UTF-8.
  Throws $UNEXPECTED-END-OF-READER if not enough data is available.

  See $read-string.
  */
  peek-string n/int -> string:
    if n == 0: return ""
    ensure-buffered n
    if first-bytes-position_ + n < buffered_.first.size:
      return buffered_.first.to_string first-bytes-position_ (first-bytes-position_ + n)
    return (peek-bytes n).to-string

  /**
  Returns a string of the given size $n.

  The bytes must be valid UTF-8.
  Throws $UNEXPECTED-END-OF-READER if not enough data is available.

  See $peek-string.
  */
  read-string n/int -> string:
    str := peek-string n
    skip n
    return str

  /**
  Searches for the first occurrence of the given byte $b.

  If $to is given, stops the search at the given position $to (exclusive).

  If necessary buffers more data.
  if $throw-if-missing is true, throws $UNEXPECTED-END-OF-READER if the byte
    is not found.
  Otherwise, returns -1, if the byte cannot be found in the remaining data.
  */
  index-of b/int --throw-if-missing/bool=false --to/int=int.MAX -> int:
    offset := 0
    start := first-bytes-position_
    buffered_.do:
      end := min (start + to) it.size
      index := it.index-of b --from=start --to=end
      if index >= 0: return offset + index
      offset += it.size - start
      to -= it.size - start
      if to <= 0:
        if throw-if-missing: throw UNEXPECTED-END-OF-READER
        return -1
      start = 0

    while true:
      if to <= 0 or not more_:
        if throw-if-missing: throw UNEXPECTED-END-OF-READER
        return -1
      bytes := buffered_.last
      end := min (start + to) bytes.size
      index := bytes.index-of b
      if index >= 0: return offset + index
      offset += bytes.size
      to -= bytes.size

  /**
  Reads at most $max-size bytes.

  Throws $UNEXPECTED-END-OF-READER if no more data is available.
  */
  read-at-most max_size/int -> ByteArray:
    ensure-buffered 1
    bytes := buffered_.first
    if first-bytes-position_ == 0 and bytes.size <= max_size:
      buffered_.remove-first
      return bytes
    size := min (bytes.size - first-bytes-position_) max_size
    result := bytes[first-bytes-position_..size]
    first-bytes-position_ += size
    if first-bytes-position_ == bytes.size: buffered_.remove-first
    return result

  /**
  Reads a line.

  If $keep-newline is true, the returned string includes the newline character.
  If $keep-newline is false, trims the trailing '\r\n' ar '\n'. This method
    removes a '\r' even if the platform is not Windows. If the '\r' needs to be
    preserved, set $keep-newline to true and remove the trailing '\n' manually.

  Returns null if no more data is available.
  */
  read-line --keep-newline/bool=false -> string?:
    if not can-ensure 1: return null
    delimiter-pos := index-of '\n'
    if delimiter_pos == null:
      return read_string buffered-size

    if keep_newline: return read_string delimiter_pos

    result_size := delimiter_pos
    if delimiter_pos > 0 and (peek_byte delimiter_pos - 1) == '\r':
      result_size--

    result := peek_string result_size
    skip delimiter_pos + 1  // Also consume the delimiter.
    return result

  /**
  Reads the remaining data as lines.

  See $read-line.
  */
  read-lines --keep-newlines/bool=false -> List:
    result := []
    while line := read-line --keep-newline=keep-newlines:
      result.add line
    return result

  /**
  Reads a string up to the given $delimiter character.

  If $consume-delimiter is true (the default), consumes the delimiter.
  The returned string does never contain the delimiter.
  Throws $UNEXPECTED-END-OF-READER if the delimiter is not found.

  See $read-bytes-until.
  */
  read-string-until delimiter/int --consume-delimiter/bool=true -> string:
    index := index-of delimiter
    if index < 0: throw UNEXPECTED-END-OF-READER
    str := read-string (index_of delimiter)
    skip 1 // Skip delimiter char
    return str

  /**
  Reads a byte array up to the given $delimiter character.

  If $consume-delimiter is true, consumes the delimiter.
  The returned byte array does never contain the delimiter.
  Throws $UNEXPECTED-END-OF-READER if the delimiter is not found.

  See $read-string-until.
  */
  read-bytes-until delimiter/int --consume-delimiter/bool=true -> ByteArray:
    bytes := read_bytes (index_of delimiter)
    skip 1 // Skip delimiter char
    return bytes

  /**
  Prepends the values in the $value byte-array.
  These will be the first bytes to be read in subsequent read
    operations.

  If $hand-over is true, then this instance takes ownership of $value.
    In this case, its contents should not be modified after being
    given to this method.
  */
  unget value/ByteArray --hand-over/bool=false -> none:
    if value.size == 0: return
    if not hand-over: value = value.copy
    if first-bytes-position_ != 0:
      first := buffered_.remove-first
      first = first[first-bytes-position_..]
      buffered_.add-first first
      first-bytes-position_ = 0
    buffered_.add-first value

  /**
  Provides endian-aware functions to read from this instance.

  The little-endian byte order reads lower-order ("little") bytes first.
    For example, if the source of the read operation is a byte array, then
    first byte read (from position 0) is the least significant byte of the
    number that is read.

  # Examples
  ```
  import io

  main:
    reader := io.Reader #[0x78, 0x56, 0x34, 0x12]
    number := reader.little-endian.read-int32
    // The least significant byte 0x78 was at index 0.
    print "0x$(%x number)"  // => 0x12345678
  ```
  */
  little-endian -> EndianReader:
    return EndianReader --reader=this --byte-order=binary.LITTLE_ENDIAN

  /**
  Provides endian-aware functions to read from this instance.

  The big-endian byte order reads higher-order (big) bytes first.
    For example, if the source of the read operation is a byte array, then
    first byte read (from position 0) is the most significant byte of the
    number that is read.

  # Examples
  ```
  import io

  main:
    reader := io.Reader #[0x12, 0x34, 0x56, 0x78]
    number := reader.big-endian.read-int32
    // The most significant byte 0x12 was at index 0.
    print "0x$(%x number)"  // => 0x12345678
  ```
  */
  big-endian -> EndianReader:
    return EndianReader --reader=this --byte-order=binary.BIG_ENDIAN

  /**
  Reads the next byte array ignoring the buffered data.

  If the reader is closed, returns null.

  # Inheritance
  If the reader is closed while this operation is in progress, the reader must
    return null.
  */
  // This is a protected method. It should not be "private".
  abstract consume_ -> ByteArray?

  /**
  Closes this reader.

  After this method has been called, the reader's $consume_ method must return null.
  This method may be called multiple times.
  */
  // This is a protected method. It should not be "private".
  abstract close_ -> none

/**
A producer of bytes from an existing $ByteArray.

See $(Reader.constructor data).
*/
class ByteArrayReader_ extends Reader:
  data_ / ByteArray? := ?

  constructor .data_:

  consume_ -> ByteArray?:
    result := data_
    data_ = null
    return result

  close_ -> none:
    data_ = null


interface OutStrategy:
  /**
  Writes the given $data to this writer.

  Returns the number of bytes written.

  See $Writer.try-write_.
  */
  // This is a protected method. It should not be "private".
  try-write_ data/Data from/int to/int -> int

  /**
  Closes this writer.

  See $Writer.close_.
  */
  // This is a protected method. It should not be "private".
  close-writer_ -> none

class Out_ extends Writer:
  strategy_/OutStrategy

  constructor .strategy_:

  try-write_ data/Data from/int to/int -> int:
    return strategy_.try-write_ data from to

  close_ -> none:
    strategy_.close-writer_

abstract mixin OutMixin implements OutStrategy:
  out_/Out_? := null

  out -> Writer:
    if not out_: out_ = Out_ this
    return out_

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
  See $Writer.close_.
  */
  // This is a protected method. It should not be "private".
  abstract close-writer_ -> none

interface InStrategy:
  /**
  Reads the next bytes.

  See $Reader.consume_.
  */
  // This is a protected method. It should not be "private".
  consume_ -> ByteArray?

  /**
  Closes this reader.

  See $Reader.close_.
  */
  // This is a protected method. It should not be "private".
  close-reader_ -> none

class In_ extends Reader:
  strategy_/InStrategy

  constructor .strategy_:

  consume_ -> ByteArray?:
    return strategy_.consume_

  close_ -> none:
    strategy_.close-reader_

abstract mixin InMixin implements InStrategy:
  in_/In_? := null

  in -> Reader:
    if not in_: in_ = In_ this
    return in_

  /**
  Reads the next bytes.

  # Inheritance
  See $Reader.consume_.
  */
  // This is a protected method. It should not be "private".
  abstract consume_ -> ByteArray?

  /**
  Closes this reader.

  # Inheritance
  See $Reader.close_.
  */
  // This is a protected method. It should not be "private".
  abstract close-reader_ -> none

/**
A buffer that can be used to build byte data.

# Aliases
- `BytesBuilder`: Dart
- `ByteArrayOutputStream`: Java
*/
class Buffer extends Writer:
  static INITIAL-BUFFER-SIZE_ ::= 64
  static MIN-BUFFER-GROWTH_ ::= 64

  init-size_/int
  offset_ := 0
  buffer_/ByteArray := ?
  is-growable_/bool := ?

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

  If $growable is true, then the backing array might be replaced with a bigger one
    if needed.

  The current backing array can be accessed with $backing-array.
  A view, only containing the data that has been written so far, can be accessed
    with $bytes.
  */
  constructor.with-initial-size size/int --growable/bool=true:
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
  */
  resize new-size/int -> none:
    ensure_ new-size
    if new-size < offset_:
      // Clear the bytes that are no longer part of the buffer.
      buffer_.fill --from=new-size --to=offset_ 0
    offset_ = new-size

  /**
  Grows the buffer by the given $amount.

  The new bytes are initialized to 0.
  */
  grow-by amount/int -> none:
    ensure_ amount
    offset_ += amount

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

    assert: offset_ + size  <= new-size

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
    if not 0 <= at <= at + data.byte-size <= offset_: throw "INVALID_ARGUMENT"

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
  ```

  ```
  import io

  main:
    buffer := io.Buffer
    writer := buffer.little-endian
    writer.write "Can be used like a normal writer."
    writer.write-int32 0x12345678
    result := buffer.bytes
    ...
  ```
  */
  little-endian -> EndianBuffer:
    return EndianBuffer --buffer=this --byte-order=binary.LITTLE_ENDIAN

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

  ```
  import io

  main:
    buffer := io.Buffer
    writer := buffer.big-endian
    writer.write "Can be used like a normal writer."
    writer.write-int32 0x12345678
    result := buffer.bytes
    ...
  ```
  */
  big-endian -> EndianBuffer:
    return EndianBuffer --buffer=this --byte-order=binary.BIG_ENDIAN

class EndianReader:
  reader_/Reader
  endian_/binary.ByteOrder
  cached-byte-array_/ByteArray ::= ByteArray 8

  constructor --reader/Reader --byte-order/binary.ByteOrder:
    reader_ = reader
    endian_ = byte-order

  /**
  Peeks an unsigned 8-bit integer without consuming it.

  This function is an alias for $Reader.peek-byte.
  */
  peek-uint8 -> int:
    return reader_.peek-byte 0

  /**
  Reads an unsigned 8-bit integer.

  This function is an alias for $Reader.read-byte.
  */
  read-uint8 -> int:
    return reader_.read-byte

  /**
  Peeks a signed 8-bit integer without consuming it.
  */
  peek-int8 -> int:
    byte := reader_.peek-byte 0
    if (byte & 0x80) != 0: return byte - 0x100
    return byte

  /** Reads a signed 8-bit integer. */
  read-int8 -> int:
    result := peek-int8
    reader_.skip 1
    return result

  /**
  Peeks an unsigned 16-bit integer without consuming it.
  */
  peek-uint16 -> int:
    cached-byte-array_[0] = reader_.peek-byte 0
    cached-byte-array_[1] = reader_.peek-byte 1
    return endian_.uint16 cached-byte-array_ 0

  /**
  Reads an unsigned 16-bit integer.
  */
  read-uint16 -> int:
    result := peek-uint16
    reader_.skip 2
    return result

  /**
  Peeks a signed 16-bit integer without consuming it.
  */
  peek-int16 -> int:
    cached-byte-array_[0] = reader_.peek-byte 0
    cached-byte-array_[1] = reader_.peek-byte 1
    return endian_.int16 cached-byte-array_ 0

  /**
  Reads a signed 16-bit integer.
  */
  read-int16 -> int:
    result := peek-int16
    reader_.skip 2
    return result

  /**
  Peeks an unsigned 24-bit integer without consuming it.
  */
  peek-uint24 -> int:
    cached-byte-array_[0] = reader_.peek-byte 0
    cached-byte-array_[1] = reader_.peek-byte 1
    cached-byte-array_[2] = reader_.peek-byte 2
    return endian_.uint24 cached-byte-array_ 0

  /**
  Reads an unsigned 24-bit integer.
  */
  read-uint24 -> int:
    result := peek-uint24
    reader_.skip 3
    return result

  /**
  Peeks a signed 24-bit integer without consuming it.
  */
  peek-int24 -> int:
    cached-byte-array_[0] = reader_.peek-byte 0
    cached-byte-array_[1] = reader_.peek-byte 1
    cached-byte-array_[2] = reader_.peek-byte 2
    return endian_.int24 cached-byte-array_ 0

  /**
  Reads a signed 24-bit integer.
  */
  read-int24 -> int:
    result := peek-int24
    reader_.skip 3
    return result

  /**
  Peeks an unsigned 32-bit integer without consuming it.
  */
  peek-uint32 -> int:
    cached-byte-array_[0] = reader_.peek-byte 0
    cached-byte-array_[1] = reader_.peek-byte 1
    cached-byte-array_[2] = reader_.peek-byte 2
    cached-byte-array_[3] = reader_.peek-byte 3
    return endian_.uint32 cached-byte-array_ 0

  /**
  Reads an unsigned 32-bit integer.
  */
  read-uint32 -> int:
    result := peek-uint32
    reader_.skip 4
    return result

  /**
  Peeks a signed 32-bit integer without consuming it.
  */
  peek-int32 -> int:
    cached-byte-array_[0] = reader_.peek-byte 0
    cached-byte-array_[1] = reader_.peek-byte 1
    cached-byte-array_[2] = reader_.peek-byte 2
    cached-byte-array_[3] = reader_.peek-byte 3
    return endian_.int32 cached-byte-array_ 0

  /**
  Reads a signed 32-bit integer.
  */
  read-int32 -> int:
    result := peek-int32
    reader_.skip 4
    return result

  /**
  Peeks a signed 64-bit integer without consuming it.
  */
  peek-int64 -> int:
    cached-byte-array_[0] = reader_.peek-byte 0
    cached-byte-array_[1] = reader_.peek-byte 1
    cached-byte-array_[2] = reader_.peek-byte 2
    cached-byte-array_[3] = reader_.peek-byte 3
    cached-byte-array_[4] = reader_.peek-byte 4
    cached-byte-array_[5] = reader_.peek-byte 5
    cached-byte-array_[6] = reader_.peek-byte 6
    cached-byte-array_[7] = reader_.peek-byte 7
    return endian_.int64 cached-byte-array_ 0

  /**
  Reads a signed 64-bit integer.
  */
  read-int64 -> int:
    result := peek-int64
    reader_.skip 8
    return result

  /**
  Peeks a 32-bit floating-point number without consuming it.
  */
  peek-float32 -> float:
    cached-byte-array_[0] = reader_.peek-byte 0
    cached-byte-array_[1] = reader_.peek-byte 1
    cached-byte-array_[2] = reader_.peek-byte 2
    cached-byte-array_[3] = reader_.peek-byte 3
    return endian_.float32 cached-byte-array_ 0

  /**
  Reads a 32-bit floating-point number.
  */
  read-float32 -> float:
    result := peek-float32
    reader_.skip 4
    return result

  /**
  Peeks a 64-bit floating-point number without consuming it.
  */
  peek-float64 -> float:
    cached-byte-array_[0] = reader_.peek-byte 0
    cached-byte-array_[1] = reader_.peek-byte 1
    cached-byte-array_[2] = reader_.peek-byte 2
    cached-byte-array_[3] = reader_.peek-byte 3
    cached-byte-array_[4] = reader_.peek-byte 4
    cached-byte-array_[5] = reader_.peek-byte 5
    cached-byte-array_[6] = reader_.peek-byte 6
    cached-byte-array_[7] = reader_.peek-byte 7
    return endian_.float64 cached-byte-array_ 0

  /**
  Reads a 64-bit floating-point number.
  */
  read-float64 -> float:
    result := peek-float64
    reader_.skip 8
    return result


class EndianWriter:
  writer_/Writer
  endian_/binary.ByteOrder
  cached-byte-array_/ByteArray ::= ByteArray 8

  constructor --writer/Writer --byte-order/binary.ByteOrder:
    writer_ = writer
    endian_ = byte-order

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
    endian_.put-int16 cached-byte-array_ 0 value
    writer_.write cached-byte-array_ 0 2

  /** Writes an unsigned 16-bit integer, using the endiannes of this instance. */
  write-uint16 value/int -> none:
    endian_.put-uint16 cached-byte-array_ 0 value
    writer_.write cached-byte-array_ 0 2

  /** Writes a signed 24-bit integer, using the endiannes of this instance. */
  write-int24 value/int -> none:
    endian_.put-int24 cached-byte-array_ 0 value
    writer_.write cached-byte-array_ 0 3

  /** Writes an unsigned 24-bit integer, using the endiannes of this instance. */
  write-uint24 value/int -> none:
    endian_.put-uint24 cached-byte-array_ 0 value
    writer_.write cached-byte-array_ 0 3

  /** Writes a signed 32-bit integer, using the endiannes of this instance. */
  write-int32 value/int -> none:
    endian_.put-int32 cached-byte-array_ 0 value
    writer_.write cached-byte-array_ 0 4

  /** Writes an unsigned 32-bit integer, using the endiannes of this instance. */
  write-uint32 value/int -> none:
    endian_.put-uint32 cached-byte-array_ 0 value
    writer_.write cached-byte-array_ 0 4

  /** Writes a signed 64-bit integer, using the endiannes of this instance. */
  write-int64 data/int -> none:
    endian_.put-int64 cached-byte-array_ 0 data
    writer_.write cached-byte-array_ 0 8

  /** Writes a 32-bit floating-point number, using the endianness of this instance. */
  write-float32 data/float -> none:
    endian_.put-float32 cached-byte-array_ 0 data
    writer_.write cached-byte-array_ 0 4

  /** Writes a 64-bit floating-point number, using the endianness of this instance. */
  write-float64 data/float -> none:
    endian_.put-float64 cached-byte-array_ 0 data
    writer_.write cached-byte-array_ 0 8

class EndianBuffer extends EndianWriter:
  buffer_/Buffer

  constructor --buffer/Buffer --byte-order/binary.ByteOrder:
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
    endian_.put-int16 cached-byte-array_ at value
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
    endian_.put-int24 cached-byte-array_ at value
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
    endian_.put-int32 cached-byte-array_ at value
    buffer_.put --at=at cached-byte-array_ 0 4

  /**
  Writes the given unsigned uint32 $value to this buffer at the given index $at.

  This function is an alias for $put-int32.
  */
  put-uint32 --at/int value/int:
    put-int32 --at=value value

  /** Writes the given int64 $value to this buffer at the given index $at. */
  put-int64 --at/int value/int:
    endian_.put-int64 cached-byte-array_ at value
    buffer_.put --at=at cached-byte-array_ 0 8

  /** Writes the given float32 $value to this buffer at the given index $at. */
  put-float32 --at/int value/float:
    endian_.put-float32 cached-byte-array_ at value
    buffer_.put --at=at cached-byte-array_ 0 4

  /** Writes the given float64 $value to this buffer at the given index $at. */
  put-float64 --at/int value/float:
    endian_.put-float64 cached-byte-array_ at value
    buffer_.put --at=at cached-byte-array_ 0 8

/**
Adapter to use an old-style writer as $Writer.
*/
class WriterAdapter_ extends Writer:
  w_/any

  constructor .w_:

  try-write_ data/Data from/int to/int -> int:
    return w_.write data from to

  close_ -> none:
    w_.close

/**
Adapter to use an $old-reader.Reader as $Reader.
*/
class ReaderAdapter_ extends Reader:
  r_/any

  constructor .r_:

  consume_ -> ByteArray?:
    return r_.read

  close_ -> none:
    r_.close

/**
An interface for objects that can provide data of a given size.

The $size might be null to indicate that the size is unknown.
*/
interface SizedInput:
  constructor bytes/ByteArray:
    return SizedInput_ bytes.size (Reader bytes)

  constructor size/int reader/Reader:
    return SizedInput_ size reader

  /**
  The amount of bytes the reader $in can produce.

  May be null to indicate that the size is unknown. This case must be
    explicitly allowed by receivers of this object.
  */
  size -> int?

  /** The reader that provides data. */
  in -> Reader

class SizedInput_ implements SizedInput:
  size/int?
  in/Reader

  constructor .size .in:

/**
Executes the given $block on chunks of the $data if the error indicates
  that the data is not of the correct type.

This function is primarily intended to be used for primitives that can
  handle the data in chunks. For example checksums, or writing to a socket/file.
*/
primitive-redo-chunked-io-data_ error data/Data from/int=0 to/int=data.byte-size [block] -> none:
  if error != "WRONG_BYTES_TYPE": throw error
  List.chunk-up from to 4096: | chunk-from chunk-to chunk-size |
    chunk := ByteArray.from data chunk-from chunk-to
    block.call chunk

/**
Executes the given $block with the given $data converted to a ByteArray, if
  the error indicates that the data is not of the correct type.
*/
primitive-redo-io-data_ error data/Data from/int=0 to/int=data.byte-size [block] -> any:
  if error != "WRONG_BYTES_TYPE": throw error
  return block.call (ByteArray.from data from to)
