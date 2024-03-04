// Copyright (C) 2023 Toitware ApS. All rights reserved.

import .reader

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

UNEXPECTED-END-OF-READER-EXCEPTION ::= "UNEXPECTED_END_OF_READER"

/** A reader wrapper that buffers the content offered by a reader. */
class BufferedReader implements Reader:
  reader_/Reader := ?

  // An array of byte arrays that have arrived but are not yet processed.
  arrays_/ByteArrayList_ := ByteArrayList_

  // The position in the first byte array that we got to.
  first-array-position_ := 0

  // The number of bytes in byte arrays that have been used up.
  base-consumed_ := 0

  /*
  Constructs a buffered reader that wraps the given $reader_.
  **/
  constructor .reader_/Reader:

  /** Clears any buffered data. */
  clear -> none:
    arrays_ = ByteArrayList_
    base-consumed_ += first-array-position_
    first-array-position_ = 0

  /**
  Ensures a number of bytes is available.
    If this is not possible, calls $on-end.
  */
  ensure_ requested [on-end] -> none:
    if requested < 0: throw "INVALID_ARGUMENT"
    while buffered < requested:
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

  add-byte-array_ data -> none:
    arrays_.add data
    if arrays_.size == 1:
      assert: first-array-position_ == 0
      base-consumed_ += first-array-position_
      first-array-position_ = 0

  /**
  Ensures that at least $n bytes are available.

  # Errors
  At least $n bytes must be available in the underlying reader. Use
    $can-ensure if a non-throwing version is necessary.
  */
  ensure n/int -> none:
    ensure_ n: throw UNEXPECTED-END-OF-READER-EXCEPTION

  /**
  Whether $n bytes can be ensured (see $ensure).
  Tries to buffer $n bytes, and returns whether it was able to.
  */
  can-ensure n/int -> bool:
    ensure_ n: return false
    return true

  /**
  Whether $n bytes are available in the internal buffer.
  This function will not call read on the underlying reader,
    so it only tells you the bytes that can be read without
    a read operation that might block.
  */
  are-available n/int -> bool:
    return buffered >= n

  /** Reads and buffers until the end of the reader. */
  buffer-all -> none:
    while more_: null

  /**
  Amount of buffered data.
  This function will not call read on the underlying reader,
    so it only tells you the bytes that can be read without
    a read operation that might block.
  */
  buffered -> int:
    return arrays_.size-in-bytes - first-array-position_

  /**
  The number of bytes that have been consumed from the BufferedReader.
  */
  consumed -> int:
    return base-consumed_ + first-array-position_

  /**
  Skips $n bytes.

  # Errors
  At least $n bytes must be available.
  */
  skip n -> none:
    while true:
      // Skip buffered data first; we make sure to only shift (or clear)
      // the buffer-array once per iteration.
      arrays_.size.repeat:
        size := arrays_.first.size - first-array-position_

        if n < size:
          first-array-position_ += n
          return

        n -= size
        base-consumed_ += arrays_.first.size
        first-array-position_ = 0

        arrays_.remove-first

      if n == 0: return

      if not more_:
        throw UNEXPECTED-END-OF-READER-EXCEPTION

  /**
  Reads the $n'th byte from the current position.

  This operation does not consume any bytes. Use $skip or $read to advance
    this reader.

  # Errors
  At least $n + 1 bytes must be available.
  */
  byte n -> int:
    if n < 0: throw "INVALID_ARGUMENT"
    ensure n + 1
    n += first-array-position_
    arrays_.do:
      size := it.size
      if n < size: return it[n]
      n -= size
    unreachable  // ensure throws if not enough bytes are available.

  /**
  Reads the first $n bytes from the reader.

  This operation does not consume any bytes. Use $skip or $read to advance
    this reader.

  # Errors
  At least $n bytes must be available.
  */
  bytes n -> ByteArray:
    if n <= 0:
      if n == 0: return ByteArray 0
      throw "INVALID_ARGUMENT"
    ensure n
    start := first-array-position_
    first := arrays_.first
    if start + n <= first.size: return first[start..start + n]
    result := ByteArray n
    offset := 0
    arrays_.do:
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
  index-of-or-throw byte:
    index := index-of byte
    if not index: throw UNEXPECTED-END-OF-READER-EXCEPTION
    return index

  /**
  Searches forwards for the $byte.

  Consumes no bytes.

  Returns the index of the first occurrence of the $byte.
  Returns null otherwise.
  */
  index-of byte -> int?:
    offset := 0
    start := first-array-position_
    arrays_.do:
      index := it.index-of byte --from=start
      if index >= 0: return offset + (index - start)
      offset += it.size - start
      start = 0

    while true:
      if not more_: return null
      array := arrays_.last
      index := array.index-of byte
      if index >= 0: return offset + index
      offset += array.size

  /**
  Searches forwards for the $byte.

  Consumes no bytes.

  Returns the index of the first occurrence of the $byte.
  Returns -1 otherwise.
  */
  index-of byte --to/int -> int:
    offset := 0
    start := first-array-position_
    arrays_.do:
      end := min start + to it.size
      index := it.index-of byte --from=start --to=end
      if index >= 0: return offset + index - start
      to -= it.size - start
      if to <= 0: return -1
      offset += it.size - start
      start = 0

    while true:
      if not more_: throw UNEXPECTED-END-OF-READER-EXCEPTION
      array := arrays_.last
      end := min to array.size
      index := array.index-of byte --to=end
      if index >= 0: return offset + index
      to -= array.size
      if to <= 0: return -1
      offset += array.size

  /**
  Reads from the reader.

  The read bytes are consumed.

  If $max-size is specified the returned byte array will never be larger than
    that size, but it may be smaller, even if there is more data available from
    the underlying reader. Use $read-bytes to read exactly n bytes.

  Returns null if the reader is at the end.
  */
  read --max-size/int?=null -> ByteArray?:
    if arrays_.size > 0:
      array := arrays_.first
      if first-array-position_ == 0 and (max-size == null or array.size <= max-size):
        arrays_.remove-first
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
        arrays_.remove-first
      else:
        first-array-position_ = end
      return result

    array := reader_.read
    if array == null: return null
    if max-size == null or array.size <= max-size:
      base-consumed_ += array.size
      return array
    arrays_.add array
    first-array-position_ = max-size
    return array[..max-size]

  /**
  Reads up to the $max-size amount of bytes from the reader.

  The read bytes are consumed.

  # Errors
  At least 1 byte must be available.

  Deprecated.  Use $(read --max-size) instead.
  */
  read-up-to max-size/int -> ByteArray:
    if max-size < 0: throw "INVALID_ARGUMENT"
    ensure 1
    array := arrays_.first
    if first-array-position_ == 0 and array.size <= max-size:
      arrays_.remove-first
      base-consumed_ += array.size
      return array
    size := min (array.size - first-array-position_) max-size
    result := array[first-array-position_..first-array-position_ + size]
    first-array-position_ += size
    if first-array-position_ == array.size:
      base-consumed_ += array.size
      first-array-position_ = 0
      arrays_.remove-first
    return result

  /**
  Reads the first $n bytes as a string.

  The read bytes are consumed.

  # Errors
  The read bytes must be convertible to a UTF8 string.
  At least $n bytes must be available.

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
  read-string n -> string:
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
    if arrays_.size == 0:
      array := reader_.read
      if array == null: return null
      // Instead of adding the array to the arrays we may just be able more
      // efficiently pass it on in string from.
      if (max-size == null or array.size <= max-size) and array[array.size - 1] <= 0x7f:
        return array.to-string
      arrays_.add array

    array := arrays_.first

    // Ensure there is at least one full UTF-8 character.  Does a blocking read
    // if we only have part of a character.  This may throw if the stream ends
    // with a malformed UTF-8 character.
    ensure UTF-FIRST-CHAR-TABLE_[array[first-array-position_] >> 4]

    // Try to take whole byte arrays from the input and convert them
    // to strings without first having to concatenate byte arrays.
    // Remember to avoid chopping up UTF-8 characters while doing this.
    if not max-size: max-size = buffered
    if first-array-position_ == 0 and array.size <= max-size and array[array.size - 1] <= 0x7f:
      arrays_.remove-first
      base-consumed_ += array.size
      return array.to-string

    size := min buffered max-size

    start-of-last-char := size - 1
    if (byte start-of-last-char) > 0x7f:
      // There is a non-ASCII UTF-8 sequence near the end.  We need to check if
      // we are chopping it up by finding where it starts.  It will start with
      // a byte >= 0xc0.
      while (byte start-of-last-char) < 0xc0:
        start-of-last-char--
        if start-of-last-char < 0: throw "ILLEGAL_UTF_8"
      // If the UTF-8 encoding of the last character extends beyond the byte
      // array we were going to convert to a string, then start just before the
      // start of that character instead.
      if start-of-last-char + UTF-FIRST-CHAR-TABLE_[(byte start-of-last-char) >> 4] > size:
        size = start-of-last-char

    if size == 0: throw "max_size was too small to read a single UTF-8 character"

    array = read-bytes size
    return array.to-string

  /**
  Reads the first byte.

  The read byte is consumed.

  # Errors
  At least 1 byte must be available.
  */
  read-byte -> int:
    b := byte 0
    skip 1
    return b

  /**
  Reads the first $n bytes from the reader.

  The read bytes are consumed.

  At least $n bytes must be available. That is, a call to $(can-ensure n) must return true.

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
  read-bytes n -> ByteArray:
    byte-array := bytes n
    skip n
    return byte-array

  /**
  Peeks the first $n bytes and converts them to a string.

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
  peek-string n -> string:
    // Fast case.
    if n == 0: return ""
    if buffered >= n:
      first := arrays_.first
      end := first-array-position_ + n
      if first.size >= end:
        return first.to-string first-array-position_ end
    // Slow case.
    return (bytes n).to-string

  /** Deprecated. */
  read-word -> string:
    return read-until ' '

  /**
  Reads a line as a string.

  Lines are terminated by a newline character (`'\n'`) except for the final
    line.
  Carriage returns (`'\r'`) are removed from lines terminated by `'\r\n'`.
  */
  read-line keep-newlines=false -> string?:
    delimiter-pos := index-of '\n'
    if delimiter-pos == null:
      rest-size := buffered
      if rest-size == 0: return null
      return read-string rest-size

    if keep-newlines: return read-string delimiter-pos

    result-size := delimiter-pos
    if delimiter-pos > 0 and (byte delimiter-pos - 1) == '\r':
      result-size--

    result := peek-string result-size
    skip delimiter-pos + 1  // Also consume the delimiter.
    return result

  /**
  Reads the string before the $delimiter.

  The read bytes and the delimiter are consumed.

  # Errors
  The $delimiter must be available.
  */
  read-until delimiter -> string:
    length := index-of delimiter
    str := peek-string length
    skip length + 1 // Skip delimiter char
    return str

  /**
  Reads the bytes before the $delimiter.

  The read bytes and the delimiter are consumed.

  # Errors
  The $delimiter must be available.
  */
  read-bytes-until delimiter -> ByteArray:
    length := index-of delimiter
    if not length: throw UNEXPECTED-END-OF-READER-EXCEPTION
    bytes := bytes length
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
      first := arrays_.first
      arrays_.remove-first
      base-consumed_ += first-array-position_
      first = first[first-array-position_..]
      arrays_.prepend first
      first-array-position_ = 0
    base-consumed_ -= value.size
    arrays_.prepend value

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
