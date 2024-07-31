// Copyright (C) 2024 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import reader as old-reader
import .byte-order

/**
A source of bytes.

# Inheritance
Implementations must implement $read_ and may override $content-size.
*/
abstract class Reader implements old-reader.Reader:
  static UNEXPECTED-END-OF-READER ::= "UNEXPECTED_END_OF_READER"

  is-closed_/bool := false

  // An array of byte arrays that have arrived but are not yet processed.
  buffered_/ByteArrayList_? := null

  // The position in the first byte array that we got to.
  first-array-position_ := 0

  /**
  The number of bytes in byte arrays that have been used up.
  Does not yet include the bytes in the first byte array. That is,
    the total number that was given to the user is
    $processed-without-first-array_ + $first-array-position_.
  */
  processed-without-first-array_/int := 0

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

  Any cleared data is not considered $processed.
  */
  clear -> none:
    buffered_ = null
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

  If the $read_ returns null, then it is either closed or at the end.
    In either case, return null.

  If $read_ has bytes to offer, then the number of bytes read is returned.
  */
  more_ -> int?:
    data := null
    while true:
      data = read_
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
  The number of bytes that have been produced by this reader so far.
  */
  processed -> int:
    return processed-without-first-array_ + first-array-position_

  /**
  Skips over the next $n bytes.

  # Errors
  At least $n bytes must be available.
  */
  skip n/int -> none:
    if n == 0: return
    buffered := buffered_
    if not buffered:
      if not more_: throw UNEXPECTED-END-OF-READER
      // The call to $more_ may have changed $buffered_ if
      // it was null. Read the field again.
      buffered = buffered_

    while n > 0:
      if buffered.size == 0:
        if not more_: throw UNEXPECTED-END-OF-READER

      first-size := buffered.first.size
      first-position := first-array-position_
      size := first-size - first-position
      if n < size:
        first-array-position_ = first-position + n
        return

      n -= size
      processed-without-first-array_ += first-size
      buffered.remove-first
      first-array-position_ = 0

  /**
  Skips all bytes up to and including the given $delimiter.

  Returns the number of bytes skipped including the $delimiter.

  If $to is given, then the search is limited to the given range.
  If $throw-if-absent is true and the $delimiter is not in the remaining data, throws.
  If $throw-if-absent is false and the $delimiter is not in the remaining data, skips
    all remaining data.
  */
  skip-up-to delimiter/int --to/int?=null --throw-if-absent/bool=false -> int:
    skipped := 0
    while true:
      buffered := buffered_
      if not buffered or buffered.size == 0:
        if not more_:
          if throw-if-absent: throw UNEXPECTED-END-OF-READER
          return skipped
        // The call to $more_ may have changed $buffered_ if
        // it was null. Read the field again.
        buffered = buffered_
      start := first-array-position_
      while buffered.size > 0:
        chunk := buffered.first
        chunk-size := chunk.size
        end := to ? min (start + to) chunk-size : chunk-size
        index := chunk.index-of delimiter --from=start --to=end
        if index >= 0:
          next := index + 1
          if next == chunk-size:
            processed-without-first-array_ += chunk-size
            buffered.remove-first
            first-array-position_ = 0
          else:
            first-array-position_ = next
          return skipped + next - start
        if to: to -= chunk-size - start
        skipped += chunk-size - start
        processed-without-first-array_ += chunk-size
        buffered.remove-first
        first-array-position_ = 0
        start = 0

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
    while chunk := read_:
      processed-without-first-array_ += chunk.size

  /**
  Searches forwards for the $byte.

  Consumes no bytes.

  If $to is specified the search is limited to the given range.

  Returns the index of the first occurrence of the $byte.
  If $throw-if-absent is true and $byte is not in the remaining data throws.
  Returns -1 if $throw-if-absent is false and the $byte is not in the remaining data.
  */
  index-of byte/int --to/int?=null --throw-if-absent/bool=false -> int:
    absent := :
      if throw-if-absent: throw UNEXPECTED-END-OF-READER
      return -1

    if to and to <= 0: absent.call

    offset := 0
    if buffered_:
      start := first-array-position_
      buffered_.do:
        end := to ? min (start + to) it.size : it.size
        index := it.index-of byte --from=start --to=end
        if index >= 0: return offset + (index - start)
        if to:
          to -= it.size - start
          if to <= 0: absent.call
        offset += it.size - start
        start = 0

    while true:
      if not more_: absent.call
      array := buffered_.last
      end := to ? min to array.size : array.size
      index := array.index-of byte --from=0 --to=end
      if index >= 0: return offset + index
      if to:
        to -= array.size
        if to <= 0: absent.call
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
        processed-without-first-array_ += array.size
        buffered_.remove-first
        return array
      byte-count := array.size - first-array-position_
      if max-size:
        byte-count = min byte-count max-size
      end := first-array-position_ + byte-count
      result := array[first-array-position_..end]
      if end == array.size:
        processed-without-first-array_ += array.size
        buffered_.remove-first
        first-array-position_ = 0
      else:
        first-array-position_ = end
      return result

    array := read_
    if array == null: return null
    if max-size == null or array.size <= max-size:
      processed-without-first-array_ += array.size
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
    read -> ByteArray?: return "hellø".to-byte-array

  main:
    reader := BufferedReader MyReader
    print
      reader.read-string 6  // >> Hellø
    print
      reader.read-string 5  // >> Error!
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

  Note that this method is different from $read followed by $ByteArray.to-string
    as it ensures that the data is split into valid UTF-8 chunks.

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
      array := read_
      if array == null: return null
      // Instead of adding the array to the arrays we may just be able more
      // efficiently pass it on in string from.
      if (max-size == null or array.size <= max-size) and array[array.size - 1] <= 0x7f:
        processed-without-first-array_ += array.size
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
      processed-without-first-array_ += array.size
      buffered_.remove-first
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
  read-exactly-or-drain reader/BufferedReader n/int -> ByteArray?:
    if can-ensure n: return reader.read-bytes n
    reader.buffer-all
    if reader.buffered == 0: return null
    return reader.read-bytes reader.buffered
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
    read -> ByteArray?: return "hellø".to-byte-array

  main:
    reader := BufferedReader MyReader
    print
      reader.peek-string 6  // >> Hellø
    print
      reader.peek-string 5  // >> Error!
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
  Calls the given $block for each remaining line.

  See $read-line.
  */
  do --lines/True --keep-newlines/bool=false [block] -> none:
    while line := read-line --keep-newline=keep-newlines:
      block.call line

  /**
  Reads the string before the $delimiter.

  The read bytes and the delimiter are consumed.
  The returned string does not include the delimiter.

  # Errors
  The $delimiter must be available.
  */
  read-string-up-to delimiter/int -> string:
    length := index-of delimiter --throw-if-absent
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
    length := index-of delimiter --throw-if-absent
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
      processed-without-first-array_ += first-array-position_
      first = first[first-array-position_..]
      buffered_.prepend first
      first-array-position_ = 0
    processed-without-first-array_ -= value.size
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
    if not result or result.byte-order_ != LITTLE-ENDIAN:
      result = EndianReader --reader=this --byte-order=LITTLE-ENDIAN
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
    if not result or result.byte-order_ != BIG-ENDIAN:
      result = EndianReader --reader=this --byte-order=BIG-ENDIAN
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
  abstract read_ -> ByteArray?

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

  Deprecated. Use $mark-closed_ instead.
  */
  // This is a protected method. It should not be "private".
  close-reader_:
    is-closed_ = true

  /**
  Marks this reader as closed.

  Sets the internal boolean to 'closed'.
  Further reads return null.
  */
  // This is a protected method. It should not be "private".
  mark-closed_:
    is-closed_ = true

abstract class CloseableReader extends Reader:
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
    try:
      close_
    finally:
      mark-closed_

  /** Whether this reader is closed. */
  is-closed -> bool:
    return is-closed_

  /**
  Closes this reader.

  After this method has been called, the reader's $read_ method must return null.
  This method may be called multiple times.

  # Inheritance
  If a read is already in process, it should be aborted and return null.
  */
  // This is a protected method. It should not be "private".
  abstract close_ -> none

abstract mixin InMixin:
  _in_/In_? := null

  in -> Reader:
    result := _in_
    if not result:
      result = In_ this
      _in_ = result
    return _in_

  /**
  Closes the reader if it exists.

  The $in $Reader doesn't have a 'close' method. However, we can set
    the internal boolean to closed, so that further reads return null.

  Any existing read needs to be aborted by the caller of this method. The $read_
    method should return null.

  Deprecated. Use $mark-reader-closed_ instead.
  */
  // This is a protected method. It should not be "private".
  close-reader_ -> none:
    if _in_: _in_.mark-closed_

  /**
  Marks the reader as closed.

  The $in $Reader doesn't have a 'close' method. It only sets the
    the internal boolean to closed, so that further reads return null.

  Any existing read needs to be aborted by the caller of this method. The $read_
    method should then return null.
  */
  // This is a protected method. It should not be "private".
  mark-reader-closed_ -> none:
    if _in_: _in_.mark-closed_

  /**
  Reads the next bytes.

  # Inheritance
  See $Reader.read_.
  */
  // This is a protected method. It should not be "private".
  abstract read_ -> ByteArray?

abstract mixin CloseableInMixin:
  _in_/CloseableIn_? := null

  in -> CloseableReader:
    if not _in_: _in_ = CloseableIn_ this
    return _in_

  /**
  Marks the reader as closed.

  The $in $Reader doesn't have a 'close' method. It only sets the
    the internal boolean to closed, so that further reads return null.

  Any existing read needs to be aborted by the caller of this method. The $read_
    method should then return null.
  */
  // This is a protected method. It should not be "private".
  mark-reader-closed_ -> none:
    if _in_: _in_.mark-closed_

  /**
  Reads the next bytes.

  # Inheritance
  See $Reader.read_.
  */
  // This is a protected method. It should not be "private".
  abstract read_ -> ByteArray?

  /**
  Closes this reader.

  # Inheritance
  See $CloseableReader.close_.
  */
  // This is a protected method. It should not be "private".
  abstract close-reader_ -> none

/**
A producer of bytes from an existing $ByteArray.

See $(Reader.constructor data).
*/
class ByteArrayReader_ extends Reader:
  data_ / ByteArray? := ?
  content-size / int := ?

  constructor .data_/ByteArray:
    content-size = data_.size

  read_ -> ByteArray?:
    result := data_
    data_ = null
    return result

  close_ -> none:
    data_ = null

// TODO(florian): make it possible to set the content-size of the reader when
// using a mixin.
class In_ extends Reader:
  mixin_/InMixin

  constructor .mixin_:

  read_ -> ByteArray?:
    return mixin_.read_

// TODO(florian): make it possible to set the content-size of the reader when
// using a mixin.
class CloseableIn_ extends CloseableReader:
  mixin_/CloseableInMixin

  constructor .mixin_:

  read_ -> ByteArray?:
    return mixin_.read_

  close_ -> none:
    mixin_.close-reader_

class EndianReader:
  reader_/Reader
  byte-order_/ByteOrder
  cached-byte-array_/ByteArray ::= ByteArray 8

  constructor --reader/Reader --byte-order/ByteOrder:
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

/**
Adapter to use an $old-reader.Reader as $Reader.
*/
class ReaderAdapter_ extends Reader:
  r_/any

  constructor .r_:

  read_ -> ByteArray?:
    return r_.read

  content-size -> int?:
    if r_ is old-reader.SizedReader:
      return (r_ as old-reader.SizedReader).size
    return null

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
