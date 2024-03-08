// Copyright (C) 2023 Toitware ApS. All rights reserved.

import binary
import reader as old-reader
import writer as old-writer

/**
A producer of bytes.

The most important implementations of this interface are
  $ByteArray and $string, which we call "Primitive IO Data". Any other data
  structure that implements this interface can still be used as byte-source
  for primitive operations but will first be converted to a byte array,
  using the $write-to-byte-array method. Some primitive operations will
  do this in a chunked way to avoid allocating a large byte array.

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

# Inheritance
The method $try-write_ must be implemented by subclasses.
The method $flush_ may be implemented by subclasses. The default implementation does nothing.
*/
abstract mixin Writer:
  is-closed_/bool := false
  endian_/EndianWriter? := null
  byte-cache_/ByteArray? := null
  written_/int := 0

  constructor:

  /**
  Constructor to convert old-style writers to this writer.

  The $writer must either be a $old-writer.Writer or a class with a `write` function
    that returns the number of bytes written.
  */
  constructor.adapt writer:
    return WriterAdapter_ writer

  /**
  The amount of bytes that have been written so far.
  */
  written -> int:
    return written_

  /**
  Writes the given $data to this writer.

  Returns the amount of bytes written (to - from).

  If the writer can't write all the data at once tries again until all of the data is
    written. This method is blocking.
  */
  write data/Data from/int=0 to/int=data.byte-size --flush/bool=false -> int:
    pos := from
    while not is-closed_ and pos < to:
      pos += try-write data pos to
      if pos < to: wait-for-more-room_
    if pos >= to:
      if flush: this.flush
      return (to - from)
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
  */
  flush -> none:
    flush_

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
    written_ += written
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
    if not endian_ or endian_.byte-order_ != binary.LITTLE_ENDIAN:
      endian_ = EndianWriter --writer=this --byte-order=binary.LITTLE_ENDIAN
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
    if not endian_ or endian_.byte-order_ != binary.BIG_ENDIAN:
      endian_ = EndianWriter --writer=this --byte-order=binary.BIG_ENDIAN
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
  Flushes any buffered data to the underlying resource.
  */
  flush_ -> none:
    // Do nothing.

  /**
  Closes this writer.

  Sets the internal boolean to 'closed'.
  Further writes throw an exception.
  */
  // This is a protected method. It should not be "private".
  close-writer_:
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

abstract mixin CloseableWriter extends Writer:
  /**
  Closes this writer.

  After this method has been called, no more data can be written to this writer.
  This method may be called multiple times.
  */
  close:
    if is-closed_: return
    close_
    is-closed_ = true

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

/**
A source of bytes.

# Inheritance
Implementations must implement $consume_ and may override $content-size.
*/
abstract mixin Reader implements old-reader.Reader:
  static UNEXPECTED-END-OF-READER ::= "UNEXPECTED_END_OF_READER"

  is-closed_/bool := false

  // An array of byte arrays that have arrived but are not yet processed.
  buffered_/ByteArrayList_? := null

  // The position in the first byte array that we got to.
  first-array-position_ := 0

  // The number of bytes in byte arrays that have been used up.
  base-consumed_ := 0

  /** A cached endian-aware reader. */
  endian_/EndianReader? := null

  constructor:

  /**
  Constructs a new reader that uses the given $data as source.
  */
  constructor data/ByteArray:
    return ByteArrayReader_ data

  /**
  Constructs a new reader that wraps the old-style reader $r.

  This constructor will be removed and should only be used temporarily.
  */
  constructor.adapt r/old-reader.Reader:
    return ReaderAdapter_ r

  /**
  Clears any buffered data.

  Any cleared data is not considered consumed.
  */
  clear -> none:
    buffered_ = null
    base-consumed_ += first-array-position_
    first-array-position_ = 0

  /**
  Ensures that $requested bytes are available.

  If this is not possible, invokes $on-end.
  */
  ensure_ requested/int [on-end] -> none:
    if requested < 0: throw "INVALID_ARGUMENT"
    while buffered-size < requested:
      if not more_: on-end.call

  /**
  Reads more data from the reader.

  If the $consume_ returns null, then it is either closed or at the end.
    In either case, return null.

  If $consume_ has bytes to offer, then the number of bytes read is returned.
  */
  more_ -> int?:
    data := null
    while true:
      data = consume_
      if not data: return null
      if data.size != 0: break
    add-byte-array_ data
    return data.size

  /**
  Buffers the given $data.
  */
  add-byte-array_ data/ByteArray -> none:
    if not buffered_: buffered_ = ByteArrayList_
    buffered_.add data
    if buffered_.size == 1:
      assert: first-array-position_ == 0
      base-consumed_ += first-array-position_
      first-array-position_ = 0

  /**
  Ensures that at least $n bytes are buffered.

  # Errors
  At least $n bytes must be available. Use $try-ensure-buffered for a non-throwing
    version.
  */
  ensure-buffered n/int -> none:
    ensure_ n: throw UNEXPECTED-END-OF-READER

  /**
  Attempts to buffer at least $n bytes.

  Returns whether it was able to.
  */
  try-ensure-buffered n/int -> bool:
    ensure_ n: return false
    return true

  /**
  Whether $n bytes are available in the internal buffer.

  This function does not read any new data from the resource, but
    only uses the buffered data.

  See $buffered-size.
  */
  is-buffered n/int -> bool:
    return buffered-size >= n

  /**
  Buffers all the remaining data of this reader.

  Use $buffered-size to determine how much data was buffered.
  Use $read-bytes to read the buffered data.
  */
  buffer-all -> none:
    while more_: null

  /**
  The amount of buffered data.

  This function does not read any new data from the resource, but
    only uses the buffered data.
  */
  buffered-size -> int:
    if not buffered_: return 0
    return buffered_.size-in-bytes - first-array-position_

  /**
  The number of bytes that have been consumed from the BufferedReader.
  */
  consumed -> int:
    return base-consumed_ + first-array-position_

  /**
  Skips over the next $n bytes.

  # Errors
  At least $n bytes must be available.
  */
  skip n/int -> none:
    if n == 0: return
    if not buffered_:
      if not more_: throw UNEXPECTED-END-OF-READER

    while n > 0:
      if buffered_.size == 0:
        if not more_: throw UNEXPECTED-END-OF-READER

      size := buffered_.first.size - first-array-position_
      if n < size:
        first-array-position_ += n
        return

      n -= size
      base-consumed_ += buffered_.first.size
      first-array-position_ = 0
      buffered_.remove-first

  /**
  Gets the $n th byte from our current position.
  Does not consume the data, but caches it in this instance.

  If enough data is already cached simply returns the byte without
    requesting more data.

  See $read-byte.

  # Errors
  At least $n + 1 bytes must be available.
  */
  peek-byte n/int=0 -> int:
    if n < 0: throw "INVALID_ARGUMENT"
    ensure-buffered n + 1
    n += first-array-position_
    buffered_.do:
      size := it.size
      if n < size: return it[n]
      n -= size
    unreachable  // ensure throws if not enough bytes are available.

  /**
  Gets the $n next bytes.
  Does not consume the data, but caches it in this instance.

  If enough data is already cached simply returns the bytes without
    requesting more data.

  See $read-bytes.

  # Errors
  At least $n bytes must be available.
  */
  peek-bytes n/int -> ByteArray:
    if n <= 0:
      if n == 0: return #[]
      throw "INVALID_ARGUMENT"
    ensure-buffered n
    start := first-array-position_
    first := buffered_.first
    if start + n <= first.size: return first[start..start + n]
    result := ByteArray n
    offset := 0
    buffered_.do:
      size := min
          it.size - start
          n - offset
      result.replace offset it start (start + size)
      offset += size
      if offset == n: return result
      start = 0
    unreachable

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
    while chunk := consume_:
      base-consumed_ += chunk.size

  /**
  Searches forwards for the $byte.

  Consumes no bytes.

  If $to is specified the search is limited to the given range.

  Returns the index of the first occurrence of the $byte.
  If $throw-if-missing is true and $byte is not in the remaining data throws.
  Returns -1 if $throw-if-missing is false and the $byte is not in the remaining data.
  */
  index-of byte/int --to/int?=null --throw-if-missing/bool=false -> int:
    offset := 0
    start := first-array-position_
    if buffered_:
      buffered_.do:
        end := to ? min (start + to) it.size : it.size
        index := it.index-of byte --from=start --to=end
        if index >= 0: return offset + (index - start)
        if to: to -= it.size - start
        offset += it.size - start
        start = 0

    while true:
      if not more_:
        if throw-if-missing: throw UNEXPECTED-END-OF-READER
        return -1
      array := buffered_.last
      end := to ? min to array.size : array.size
      index := array.index-of byte
      if index >= 0: return offset + index
      if to: to -= array.size
      offset += array.size

  /**
  Reads from the reader.

  If data has been buffered returns the buffered data first. Otherwise, attempts
    to read new data from the resource.

  The read bytes are consumed.

  If $max-size is specified the returned byte array will never be larger than
    that size, but it may be smaller, even if there is more data available from
    the underlying resource. Use $read-bytes to read exactly n bytes.

  Returns null if no more data is available.
  */
  read --max-size/int?=null -> ByteArray?:
    if buffered_ and buffered_.size > 0:
      array := buffered_.first
      if first-array-position_ == 0 and (max-size == null or array.size <= max-size):
        buffered_.remove-first
        base-consumed_ += array.size
        return array
      byte-count := array.size - first-array-position_
      if max-size:
        byte-count = min byte-count max-size
      end := first-array-position_ + byte-count
      result := array[first-array-position_..end]
      if end == array.size:
        base-consumed_ += array.size
        first-array-position_ = 0
        buffered_.remove-first
      else:
        first-array-position_ = end
      return result

    array := consume_
    if array == null: return null
    if max-size == null or array.size <= max-size:
      base-consumed_ += array.size
      return array
    add-byte-array_ array
    first-array-position_ = max-size
    return array[..max-size]

  /**
  Reads the first $n bytes as a string.

  The read bytes are consumed.

  # Errors
  The read bytes must be convertible to a UTF8 string.
  At least $n bytes must be available.

  See $peek-string.

  # Examples
  ```
  class MyReader implements Reader:
    read -> ByteArray?: return "hellø".to_byte_array

  main:
    reader := BufferedReader MyReader
    print
      reader.read_string 6  // >> Hellø
    print
      reader.read_string 5  // >> Error!
  ```
  */
  read-string n/int -> string:
    str := peek-string n
    skip n
    return str

  // Indexed by the top nibble of a UTF-8 byte this tells you how many bytes
  // long the UTF-8 sequence is.
  static UTF-FIRST-CHAR-TABLE_ ::= [
    1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 2, 2, 3, 4,
  ]

  /**
  Reads at most $max-size bytes as a string.

  The read bytes are consumed.

  Note that this method is different from $read followed by to_string as it
    ensures that the data is split into valid UTF-8 chunks.

  If $max-size is specified the returned string will never be larger than
    that size (in bytes), but it may be smaller, even if there is more data
    available from the underlying reader.

  Returns null if the stream has ended.

  # Errors
  The read bytes must be convertible to a legal UTF8 string, but this method
    will read a number of bytes such that legal UTF-8 characters are not
    chopped up.

  May throw an end-of-stream exception if the stream ends in the middle of a
    malformed UTF-8 character.

  Instead of returning a zero length string it throws an exception.  This can
    happen if $max-size is less than 4 bytes and the next thing is a UTF-8
    character that is coded in more bytes than were requested.  This also means
    $max-size should never be zero.
  */
  read-string --max-size/int?=null -> string?:
    if max-size and max-size < 0: throw "INVALID_ARGUMENT"
    if not buffered_ or buffered_.size == 0:
      array := consume_
      if array == null: return null
      // Instead of adding the array to the arrays we may just be able more
      // efficiently pass it on in string from.
      if (max-size == null or array.size <= max-size) and array[array.size - 1] <= 0x7f:
        base-consumed_ += array.size
        return array.to-string
      add-byte-array_ array

    array := buffered_.first

    // Ensure there is at least one full UTF-8 character.  Does a blocking read
    // if we only have part of a character.  This may throw if the stream ends
    // with a malformed UTF-8 character.
    ensure-buffered UTF-FIRST-CHAR-TABLE_[array[first-array-position_] >> 4]

    // Try to take whole byte arrays from the input and convert them
    // to strings without first having to concatenate byte arrays.
    // Remember to avoid chopping up UTF-8 characters while doing this.
    if not max-size: max-size = buffered-size
    if first-array-position_ == 0 and array.size <= max-size and array[array.size - 1] <= 0x7f:
      buffered_.remove-first
      base-consumed_ += array.size
      return array.to-string

    size := min buffered-size max-size

    start-of-last-char := size - 1
    if (peek-byte start-of-last-char) > 0x7f:
      // There is a non-ASCII UTF-8 sequence near the end.  We need to check if
      // we are chopping it up by finding where it starts.  It will start with
      // a byte >= 0xc0.
      while (peek-byte start-of-last-char) < 0xc0:
        start-of-last-char--
        if start-of-last-char < 0: throw "ILLEGAL_UTF_8"
      // If the UTF-8 encoding of the last character extends beyond the byte
      // array we were going to convert to a string, then start just before the
      // start of that character instead.
      if start-of-last-char + UTF-FIRST-CHAR-TABLE_[(peek-byte start-of-last-char) >> 4] > size:
        size = start-of-last-char

    if size == 0: throw "max_size was too small to read a single UTF-8 character"

    array = read-bytes size
    return array.to-string

  /**
  Reads the first byte.

  The read byte is consumed.

  See $peek-byte.

  # Errors
  At least 1 byte must be available.
  */
  read-byte -> int:
    b := peek-byte 0
    skip 1
    return b

  /**
  Reads the first $n bytes from the reader.

  The read bytes are consumed.

  At least $n bytes must be available. That is, a call to $(try-ensure-buffered n) must return true.

  If you want to read either $n bytes, if they are available, or the maximum number of
    available bytes otherwise, use the following code:

  ```
  read_exactly_or_drain reader/BufferedReader n/int -> ByteArray?:
    if can_ensure n: return reader.read_bytes n
    reader.buffer_all
    if reader.buffered == 0: return null
    return reader.read_bytes reader.buffered
  ```
  */
  read-bytes n/int -> ByteArray:
    byte-array := peek-bytes n
    skip n
    return byte-array

  /**
  Gets the first $n bytes and returns them as string.

  Does not consume the data, but caches it in this instance.

  # Errors
  The peeked bytes must be convertible to a UTF8 string.
  At least $n bytes must be available.

  # Examples
  ```
  class MyReader implements Reader:
    read -> ByteArray?: return "hellø".to_byte_array

  main:
    reader := BufferedReader MyReader
    print
      reader.peek_string 6  // >> Hellø
    print
      reader.peek_string 5  // >> Error!
  ```
  */
  peek-string n/int -> string:
    // Fast case.
    if n == 0: return ""
    if buffered-size >= n:
      first := buffered_.first
      end := first-array-position_ + n
      if first.size >= end:
        return first.to-string first-array-position_ end
    // Slow case.
    return (peek-bytes n).to-string

  /**
  Reads a line as a string.

  If $keep-newline is true, the returned string includes the newline character.
  If $keep-newline is false, trims the trailing '\r\n' or '\n'. This method
    removes a '\r' even if the platform is not Windows. If the '\r' needs to be
    preserved, set $keep-newline to true and remove the trailing '\n' manually.
  If the input ends with a newline, then all further reads return null.
  If the input ends without a newline, then the last line is returned without any
    newline character (even if $keep-newline) is true, and all further reads
    return null.

  Returns null if no more data is available.
  */
  read-line --keep-newline/bool=false -> string?:
    delimiter-pos := index-of '\n'
    if delimiter-pos == -1:
      rest-size := buffered-size
      if rest-size == 0: return null
      return read-string rest-size

    if keep-newline: return read-string (delimiter-pos + 1)

    result-size := delimiter-pos
    if delimiter-pos > 0 and (peek-byte (delimiter-pos - 1)) == '\r':
      result-size--

    result := peek-string result-size
    skip delimiter-pos + 1  // Also consume the delimiter.
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
  Reads the string before the $delimiter.

  The read bytes and the delimiter are consumed.
  The returned string does not include the delimiter.

  # Errors
  The $delimiter must be available.
  */
  read-string-up-to delimiter/int -> string:
    length := index-of delimiter --throw-if-missing
    str := peek-string length
    skip length + 1 // Skip delimiter char
    return str

  /**
  Reads the bytes before the $delimiter.

  The read bytes and the delimiter are consumed.
  The returned bytes do not include the delimiter.

  # Errors
  The $delimiter must be available.
  */
  read-bytes-up-to delimiter/int -> ByteArray:
    length := index-of delimiter --throw-if-missing
    bytes := peek-bytes length
    skip length + 1 // Skip delimiter char
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
    if first-array-position_ != 0:
      first := buffered_.first
      buffered_.remove-first
      base-consumed_ += first-array-position_
      first = first[first-array-position_..]
      buffered_.prepend first
      first-array-position_ = 0
    base-consumed_ -= value.size
    if not buffered_: buffered_ = ByteArrayList_
    buffered_.prepend value

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
    result := endian_
    if not result or result.byte-order_ != binary.LITTLE_ENDIAN:
      result = EndianReader --reader=this --byte-order=binary.LITTLE_ENDIAN
      endian_ = result
    return result

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
    result := endian_
    if not result or result.byte-order_ != binary.BIG_ENDIAN:
      result = EndianReader --reader=this --byte-order=binary.BIG_ENDIAN
      endian_ = result
    return result

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
  The total number of bytes that this reader can produce.
  This value is not updated when data is consumed.

  If the reader does not know the size, returns null.
  */
  content-size -> int?:
    return null

  /**
  Closes this reader.

  Sets the internal boolean to 'closed'.
  Further reads return null.
  */
  // This is a protected method. It should not be "private".
  close-reader_:
    is-closed_ = true

abstract mixin CloseableReader extends Reader:
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
    close-reader_

  /** Whether this reader is closed. */
  is-closed -> bool:
    return is-closed_

  /**
  Closes this reader.

  After this method has been called, the reader's $consume_ method must return null.
  This method may be called multiple times.

  # Inheritance
  If a read is already in process, it should be aborted and return null.
  */
  // This is a protected method. It should not be "private".
  abstract close_ -> none

/**
A producer of bytes from an existing $ByteArray.

See $(Reader.constructor data).
*/
class ByteArrayReader_ extends Object with Reader:
  data_ / ByteArray? := ?
  content-size / int := ?

  constructor .data_/ByteArray:
    content-size = data_.size

  consume_ -> ByteArray?:
    result := data_
    data_ = null
    return result

  close_ -> none:
    data_ = null

class Out_ extends Object with Writer:
  mixin_/OutMixin

  constructor .mixin_:

  try-write_ data/Data from/int to/int -> int:
    return mixin_.try-write_ data from to

class CloseableOut_ extends Object with CloseableWriter:
  mixin_/CloseableOutMixin

  constructor .mixin_:

  try-write_ data/Data from/int to/int -> int:
    return mixin_.try-write_ data from to

  close_ -> none:
    mixin_.close-writer_

abstract mixin OutMixin:
  out_/Out_? := null

  out -> Writer:
    result := out_
    if not result:
      result = Out_ this
      out_ = result
    return result

  /**
  Closes the writer if it exists.

  The $out $Writer doesn't have a 'close' method. However, we can set
    the internal boolean to `closed`, so that further writes throw an exception, or
    that existing writes are aborted.

  Any existing write needs to be aborted by the caller of this method.
    The `try-write_` should either throw or return the number of bytes that have been
    written so far. See $CloseableWriter.close_.
  */
  // This is a protected method. It should not be "private".
  close-writer_ -> none:
    if out_: out_.close-writer_

  /**
  Writes the given $data to this writer.

  Returns the number of bytes written.

  # Inheritance
  See $Writer.try-write_.
  */
  // This is a protected method. It should not be "private".
  abstract try-write_ data/Data from/int to/int -> int

abstract mixin CloseableOutMixin:
  out_/CloseableOut_? := null

  out -> CloseableWriter:
    if not out_: out_ = CloseableOut_ this
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
  See $CloseableWriter.close_.
  */
  // This is a protected method. It should not be "private".
  abstract close-writer_ -> none

// TODO(florian): make it possible to set the content-size of the reader when
// using a mixin.
class In_ extends Object with Reader:
  mixin_/InMixin

  constructor .mixin_:

  consume_ -> ByteArray?:
    return mixin_.consume_

// TODO(florian): make it possible to set the content-size of the reader when
// using a mixin.
class CloseableIn_ extends Object with CloseableReader:
  mixin_/CloseableInMixin

  constructor .mixin_:

  consume_ -> ByteArray?:
    return mixin_.consume_

  close_ -> none:
    mixin_.close-reader_

abstract mixin InMixin:
  in_/In_? := null

  in -> Reader:
    result := in_
    if not result:
      result = In_ this
      in_ = result
    return in_

  /**
  Closes the writer if it exists.

  The $in $Reader doesn't have a 'close' method. However, we can set
    the internal boolean to `closed`, so that further reads return 'null'.

  Any existing read needs to be aborted by the caller of this method. The `consume`
    method should return 'null'.
  */
  // This is a protected method. It should not be "private".
  close-reader_ -> none:
    if in_: in_.close-reader_

  /**
  Reads the next bytes.

  # Inheritance
  See $Reader.consume_.
  */
  // This is a protected method. It should not be "private".
  abstract consume_ -> ByteArray?

abstract mixin CloseableInMixin:
  in_/CloseableIn_? := null

  in -> CloseableReader:
    if not in_: in_ = CloseableIn_ this
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
  See $CloseableReader.close_.
  */
  // This is a protected method. It should not be "private".
  abstract close-reader_ -> none

/**
A buffer that can be used to build byte data.

# Aliases
- `BytesBuilder`: Dart
- `ByteArrayOutputStream`: Java
*/
class Buffer extends Object with CloseableWriter:
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
    // Be sure to clear the data.
    buffer_.fill --from=offset_ --to=(offset_ + amount) 0
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
    if not result or result.byte-order_ != binary.LITTLE_ENDIAN:
      result = EndianBuffer --buffer=this --byte-order=binary.LITTLE_ENDIAN
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
    if not result or result.byte-order_ != binary.BIG_ENDIAN:
      result = EndianBuffer --buffer=this --byte-order=binary.BIG_ENDIAN
      endian_ = result
    return (result as EndianBuffer)

class EndianReader:
  reader_/Reader
  byte-order_/binary.ByteOrder
  cached-byte-array_/ByteArray ::= ByteArray 8

  constructor --reader/Reader --byte-order/binary.ByteOrder:
    reader_ = reader
    byte-order_ = byte-order

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
    return byte-order_.uint16 cached-byte-array_ 0

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
    return byte-order_.int16 cached-byte-array_ 0

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
    return byte-order_.uint24 cached-byte-array_ 0

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
    return byte-order_.int24 cached-byte-array_ 0

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
    return byte-order_.uint32 cached-byte-array_ 0

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
    return byte-order_.int32 cached-byte-array_ 0

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
    return byte-order_.int64 cached-byte-array_ 0

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
    return byte-order_.float32 cached-byte-array_ 0

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
    return byte-order_.float64 cached-byte-array_ 0

  /**
  Reads a 64-bit floating-point number.
  */
  read-float64 -> float:
    result := peek-float64
    reader_.skip 8
    return result


class EndianWriter:
  writer_/Writer
  byte-order_/binary.ByteOrder
  cached-byte-array_/ByteArray ::= ByteArray 8

  constructor --writer/Writer --byte-order/binary.ByteOrder:
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
Adapter to use an old-style writer as $Writer.
*/
class WriterAdapter_ extends Object with Writer:
  w_/any

  constructor .w_:

  try-write_ data/Data from/int to/int -> int:
    return w_.write data from to

/**
Adapter to use an $old-reader.Reader as $Reader.
*/
class ReaderAdapter_ extends Object with Reader:
  r_/any

  constructor .r_:

  consume_ -> ByteArray?:
    return r_.read

  content-size -> int?:
    if r_ is old-reader.SizedReader:
      return (r_ as old-reader.SizedReader).size
    return null

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

class Element_:
  value/ByteArray
  next/Element_? := null

  constructor .value:

class ByteArrayList_:
  head_/Element_? := null
  tail_/Element_? := null

  size := 0
  size-in-bytes := 0

  add value/ByteArray:
    element := Element_ value
    if tail_:
      tail_.next = element
    else:
      head_ = element
    tail_ = element
    size++
    size-in-bytes += value.size

  prepend value/ByteArray:
    element := Element_ value
    if head_:
      element.next = head_
    else:
      tail_ = element
    head_ = element
    size++
    size-in-bytes += value.size

  remove-first:
    element := head_
    next := element.next
    head_ = next
    if not next: tail_ = null
    size--
    size-in-bytes -= element.value.size

  first -> ByteArray: return head_.value
  last -> ByteArray: return tail_.value

  do [block]:
    for current := head_; current; current = current.next:
      block.call current.value
