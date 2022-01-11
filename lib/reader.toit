// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

UNEXPECTED_END_OF_READER_EXCEPTION ::= "UNEXPECTED_END_OF_READER"

/** A byte reader. */
interface Reader:
  /**
  Reads from the source.

  Returns a byte array if the source has available content.
  Returns null otherwise.
  */
  read -> ByteArray?

/** A byte reader that can be closed. */
interface CloseableReader implements Reader:
  /**
  See $Reader.read.

  Returns null if the reader has been closed.
  */
  read -> ByteArray?
  /** Closes the reader. */
  close -> none

/** A readable source that knows its size. */
interface SizedReader implements Reader:
  /** See $Reader.read. */
  read -> ByteArray?
  /*
  The size of the data this reader produces.
  Must only be called before the first $read.
  */
  size -> int

/** A reader wrapper that buffers the content offered by a reader. */
class BufferedReader implements Reader:
  reader_/Reader := ?

  // An array of byte arrays that have arrived but are not yet processed.
  arrays_/ByteArrayList_ := ByteArrayList_

  // The position in the first byte array that we got to.
  first_array_position_ := 0

  /*
  Constructs a buffered reader that wraps the given $reader_.
  **/
  constructor .reader_/Reader:

  /** Clears any buffered data. */
  clear -> none:
    arrays_ = ByteArrayList_
    first_array_position_ = 0

  /**
  Ensures a number of bytes is available.
    If this is not possible, calls $on_end.
  */
  ensure_ requested [on_end] -> none:
    while buffered < requested:
      if not more_: on_end.call

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
    add_byte_array_ data
    return data.size

  add_byte_array_ data -> none:
    arrays_.add data
    if arrays_.size == 1: first_array_position_ = 0

  /**
  Ensures that at least $n bytes are available.

  # Errors
  At least $n bytes must be available in the underlying reader. Use
    $can_ensure if a non-throwing version is necessary.
  */
  ensure n/int -> none:
    ensure_ n: throw UNEXPECTED_END_OF_READER_EXCEPTION

  /**
  Whether $n bytes can be ensured (see $ensure).
  Tries to buffer $n bytes, and returns whether it was able to.
  */
  can_ensure n/int -> bool:
    ensure_ n: return false
    return true

  /** Whether $n bytes are available in the internal buffer. */
  are_available n/int -> bool:
    return (byte n - 1) != -1

  /** Reads and buffers until the end of the reader. */
  buffer_all -> none:
    while more_: null

  /** Amount of buffered data. */
  buffered -> int:
    return arrays_.size_in_bytes - first_array_position_

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
        size := arrays_.first.size - first_array_position_

        if n < size:
          first_array_position_ += n
          return

        n -= size
        first_array_position_ = 0

        arrays_.remove_first

      if n == 0: return

      if not more_:
        throw UNEXPECTED_END_OF_READER_EXCEPTION

  /**
  Reads the $n'th byte from the current position.

  This operation does not consume any bytes. Use $skip or $read to advance
    this reader.

  # Errors
  At least $n + 1 bytes must be available.
  */
  byte n -> int:
    ensure n + 1
    n += first_array_position_
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
    if n == 0: return ByteArray 0
    ensure n
    start := first_array_position_
    first := arrays_.first
    if start + n <= first.size: return first[start..start+n]
    result := ByteArray n
    offset := 0
    arrays_.do:
      size := it.size - start
      if offset + size > n: size = n - offset
      result.replace offset it start start+size
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
  index_of_or_throw byte:
    index := index_of byte
    if not index: throw UNEXPECTED_END_OF_READER_EXCEPTION
    return index

  /**
  Searches forwards for the $byte.

  Consumes no bytes.

  Returns the index of the first occurrence of the $byte.
  Returns null otherwise.
  */
  index_of byte -> int?:
    offset := 0
    start := first_array_position_
    arrays_.do:
      index := it.index_of byte --from=start
      if index >= 0: return offset + (index - start)
      offset += it.size - start
      start = 0

    while true:
      if not more_: return null
      array := arrays_.last
      index := array.index_of byte
      if index >= 0: return offset + index
      offset += array.size

  /**
  Searches forwards for the $byte.

  Consumes no bytes.

  Returns the index of the first occurrence of the $byte.
  Returns -1 otherwise.
  */
  index_of byte --to/int -> int:
    offset := 0
    start := first_array_position_
    arrays_.do:
      end := min start + to it.size
      index := it.index_of byte --from=start --to=end
      if index >= 0: return offset + index - start
      to -= it.size - start
      if to <= 0: return -1
      offset += it.size - start
      start = 0

    while true:
      if not more_: throw UNEXPECTED_END_OF_READER_EXCEPTION
      array := arrays_.last
      end := min to array.size
      index := array.index_of byte --to=end
      if index >= 0: return offset + index
      to -= array.size
      if to <= 0: return -1
      offset += array.size

  /**
  Reads from the reader.

  The read bytes are consumed.

  If $max_size is specified the returned byte array will never be larger than
    that size, but it may be smaller, even if there is more data available from
    the underlying reader.

  Returns null if the reader is at the end.
  */
  read --max_size/int?=null -> ByteArray?:
    if arrays_.size > 0:
      array := arrays_.first
      if first_array_position_ == 0 and (max_size == null or array.size <= max_size):
        arrays_.remove_first
        return array
      byte_count := array.size - first_array_position_
      if max_size:
        byte_count = min byte_count max_size
      end := first_array_position_ + byte_count
      result := array[first_array_position_..end]
      if end == array.size:
        first_array_position_ = 0
        arrays_.remove_first
      else:
        first_array_position_ = end
      return result

    array := reader_.read
    if max_size == null or array == null or array.size <= max_size:
      return array
    arrays_.add array
    first_array_position_ = max_size
    return array[..max_size]

  /**
  Reads up to the $max_size amount of bytes from the reader.

  The read bytes are consumed.

  # Errors
  At least 1 byte must be available.

  Deprecated.  Use $(read --max_size) instead.
  */
  read_up_to max_size/int -> ByteArray:
    ensure 1
    array := arrays_.first
    if first_array_position_ == 0 and array.size <= max_size:
      arrays_.remove_first
      return array
    size := min (array.size - first_array_position_) max_size
    result := array[first_array_position_..first_array_position_ + size]
    first_array_position_ += size
    if first_array_position_ == array.size: arrays_.remove_first
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
  read_string n -> string:
    str := peek_string n
    skip n
    return str

  // Indexed by the top nibble of a UTF-8 byte this tells you how many bytes
  // long the UTF-8 sequence is.
  static UTF_FIRST_CHAR_TABLE_ ::= [
    1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 2, 2, 3, 4,
  ]

  /**
  Reads at most $max_size bytes as a string.

  The read bytes are consumed.

  Note that this method is different from $read followed by to_string as it
    ensures that the data is split into valid UTF-8 chunks.

  If $max_size is specified the returned string will never be larger than
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
    happen if $max_size is less than 4 bytes and the next thing is a UTF-8
    character that is coded in more bytes than were requested.  This also means
    $max_size should never be zero.
  */
  read_string --max_size/int?=null -> string?:
    if arrays_.size == 0:
      array := reader_.read
      if array == null: return null
      // Instead of adding the array to the arrays we may just be able more
      // efficiently pass it on in string from.
      if (max_size == null or array.size <= max_size) and array[array.size - 1] <= 0x7f:
        return array.to_string
      arrays_.add array

    array := arrays_.first

    // Ensure there is at least one full UTF-8 character.  Does a blocking read
    // if we only have part of a character.  This may throw if the stream ends
    // with a malformed UTF-8 character.
    ensure UTF_FIRST_CHAR_TABLE_[array[first_array_position_] >> 4]

    // Try to take whole byte arrays from the input and convert them
    // to strings without first having to concatenate byte arrays.
    // Remember to avoid chopping up UTF-8 characters while doing this.
    if not max_size: max_size = buffered
    if first_array_position_ == 0 and array.size <= max_size and array[array.size - 1] <= 0x7f:
      arrays_.remove_first
      return array.to_string

    size := min buffered max_size

    start_of_last_char := size - 1
    if (byte start_of_last_char) > 0x7f:
      // There is a non-ASCII UTF-8 sequence near the end.  We need to check if
      // we are chopping it up by finding where it starts.  It will start with
      // a byte >= 0xc0.
      while (byte start_of_last_char) < 0xc0:
        start_of_last_char--
        if start_of_last_char < 0: throw "ILLEGAL_UTF_8"
      // If the UTF-8 encoding of the last character extends beyond the byte
      // array we were going to convert to a string, then start just before the
      // start of that character instead.
      if start_of_last_char + UTF_FIRST_CHAR_TABLE_[(byte start_of_last_char) >> 4] > size:
        size = start_of_last_char

    if size == 0: throw "max_size was too small to read a single UTF-8 character"

    array = read_bytes size
    return array.to_string

  /**
  Reads the first byte.

  The read byte is consumed.

  # Errors
  At least 1 byte must be available.
  */
  read_byte -> int:
    b := byte 0
    skip 1
    return b

  /**
  Reads the first $n bytes from the reader.

  The read bytes are consumed.

  # Errors
  At least $n bytes must be available.
  */
  read_bytes n -> ByteArray:
    byte_array := bytes n
    skip n
    return byte_array

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
  peek_string n -> string:
    return (bytes n).to_string

  /** Deprecated. */
  read_word -> string:
    return read_until ' '

  /**
  Reads a line as a string.

  Lines are terminated by a newline character (`'\n'`) except for the final
    line.
  Carriage returns (`'\r'`) are removed from lines terminated by `'\r\n'`.
  */
  read_line keep_newlines = false -> string?:
    delimiter_pos := index_of '\n'
    if delimiter_pos == null:
      rest_size := buffered
      if rest_size == 0: return null
      return read_string rest_size

    if keep_newlines: return read_string delimiter_pos

    result_size := delimiter_pos
    if delimiter_pos > 0 and (byte delimiter_pos - 1) == '\r':
      result_size--

    result := peek_string result_size
    skip delimiter_pos + 1  // Also consume the delimiter.
    return result

  /**
  Reads the string before the $delimiter.

  The read bytes and the delimiter are consumed.

  # Errors
  The $delimiter must be available.
  */
  read_until delimiter -> string:
    length := index_of delimiter
    str := peek_string length
    skip length + 1 // Skip delimiter char
    return str

  /**
  Reads the bytes before the $delimiter.

  The read bytes and the delimiter are consumed.

  # Errors
  The $delimiter must be available.
  */
  read_bytes_until delimiter -> ByteArray:
    length := index_of delimiter
    if not length: throw UNEXPECTED_END_OF_READER_EXCEPTION
    bytes := bytes length
    skip length + 1 // Skip delimiter char
    return bytes

  /**
  The bytes in $value are prepended to the BufferedReader.
  These will be the first bytes to be read in subsequent read
    operations.  This takes ownership of $value so it is kept
    alive and its contents should not be modified after being
    given to the BufferedReader.
  */
  unget value/ByteArray -> none:
    if first_array_position_ != 0:
      first := arrays_.first
      arrays_.remove_first
      first = first[first_array_position_..]
      arrays_.prepend first
      first_array_position_ = 0
    arrays_.prepend value

class Element_:
  value/ByteArray
  next/Element_? := null

  constructor .value:

class ByteArrayList_:
  head_/Element_? := null
  tail_/Element_? := null

  size := 0
  size_in_bytes := 0

  add value/ByteArray:
    element := Element_ value
    if tail_:
      tail_.next = element
    else:
      head_ = element
    tail_ = element
    size++
    size_in_bytes += value.size

  prepend value/ByteArray:
    element := Element_ value
    if head_:
      element.next = head_
    else:
      tail_ = element
    head_ = element
    size++
    size_in_bytes += value.size

  remove_first:
    element := head_
    next := element.next
    head_ = next
    if not next: tail_ = null
    size--
    size_in_bytes -= element.value.size

  first -> ByteArray: return head_.value
  last -> ByteArray: return tail_.value

  do [block]:
    for current := head_; current; current = current.next:
      block.call current.value
