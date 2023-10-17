// Copyright (C) 2023 Toitware ApS. All rights reserved.

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
abstract class Reader:
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


  /**
  Reads a chunk of data.

  Returns null if no more data is left.

  If data has been buffered returns the buffered data first.
  Otherwise attempts to read new data from the resource.
  */
  read -> ByteArray?:
    if buffered_.is_empty:
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
  is_available n/int -> bool:
    return (peek_byte n - 1) != -1

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
    return ByteArray 0

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

  If necessary buffers more data.
  Returns -1, if the byte cannot be found in the remaining data.
  */
  index-of b/int -> int:
    offset := 0
    start := first-bytes-position_
    buffered_.do:
      index := it.index-of b --from=start
      if index >= 0: return offset + index
      offset += it.size - start
      start = 0

    while true:
      if not more_: return -1
      bytes := buffered_.last
      index := bytes.index-of b
      if index >= 0: return offset + index
      offset += bytes.size

  /**
  Variant of $(index-of b).

  Throws $UNEXPECTED-END-OF-READER if the byte $b is not found.
  */
  index-of b/int --throw-if-missing/bool -> int:
    if not throw-if-missing: throw "INVALID_ARGUMENT"
    index := index-of b
    if index < 0: throw UNEXPECTED-END-OF-READER
    return index

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
    if not is-available 1: return null
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

  See $read-bytes-up-to.
  */
  read-string-up-to delimiter/int --consume-delimiter/bool=true -> string:
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

  See $read-string-up-to.
  */
  read-bytes-up-to delimiter/int --consume-delimiter/bool=true -> ByteArray:
    bytes := read_bytes (index_of delimiter)
    skip 1 // Skip delimiter char
    return bytes

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
