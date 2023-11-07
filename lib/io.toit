// Copyright (C) 2023 Toitware ApS. All rights reserved.

import .reader
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

/** A reader wrapper that buffers the content offered by a reader. */
class BufferedReader implements Reader:
  static UNEXPECTED-END-OF-READER ::= "UNEXPECTED_END_OF_READER"

  reader_/Reader := ?

  // An array of byte arrays that have arrived but are not yet processed.
  buffered_/ByteArrayList_? := null

  // The position in the first byte array that we got to.
  first-array-position_ := 0

  // The number of bytes in byte arrays that have been used up.
  base-consumed_ := 0

  /*
  Constructs a buffered reader that wraps the given $reader_.
  **/
  constructor .reader_/Reader:

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

  If the the $reader_ returns null, then it is either closed or at the end.
    In either case, return null.

  If $reader_ has bytes to offer, then the number of bytes read is returned.
  */
  more_ -> int?:
    data := null
    while true:
      data = reader_.read
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
  peek-byte n/int -> int:
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
  Searches forwards for the index of the $byte.

  Consumes no bytes.

  Returns the index of the first occurrence of the $byte.
  Throws if the byte is not found.
  */
  index-of-or-throw byte/int:
    index := index-of byte
    if not index: throw UNEXPECTED-END-OF-READER
    return index

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

    array := reader_.read
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
      array := reader_.read
      if array == null: return null
      // Instead of adding the array to the arrays we may just be able more
      // efficiently pass it on in string from.
      if (max-size == null or array.size <= max-size) and array[array.size - 1] <= 0x7f:
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

  Returns null if no more data is available.
  */
  read-line --keep-newline/bool=false -> string?:
    delimiter-pos := index-of '\n'
    if delimiter-pos == null:
      rest-size := buffered-size
      if rest-size == 0: return null
      return read-string rest-size

    if keep-newline: return read-string delimiter-pos

    result-size := delimiter-pos
    if delimiter-pos > 0 and (peek-byte delimiter-pos - 1) == '\r':
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
    length := index-of delimiter
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
    length := index-of delimiter
    if not length: throw UNEXPECTED-END-OF-READER
    bytes := peek-bytes length
    skip length + 1 // Skip delimiter char
    return bytes

  /**
  The bytes in $value are prepended to the BufferedReader.
  These will be the first bytes to be read in subsequent read
    operations.  This takes ownership of $value so it is kept
    alive and its contents should not be modified after being
    given to the BufferedReader.
  This causes the $consumed count to go backwards.
  */
  unget value/ByteArray -> none:
    if value.size == 0: return
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
