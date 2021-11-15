// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import reader show CloseableReader
/**
Support for inter task reading and writing.
*/

/**
A shim that allows one task to have a read interface and the other
  task to have a blocking write interface.  Implements $write.
*/
class ReaderWriter:
  writer_/ReaderWriterHelper_ ::= ?
  reader_/CloseableReader ::= ?

  /**
  Constructs a reader-writer.

  The $buffer_size determines the size of the communication buffer.
  */
  constructor buffer_size/int=64:
    writer_ = ReaderWriterHelper_ buffer_size
    reader_ = ReaderWriterReader_ writer_

  /** The corresponding $CloseableReader. */
  reader -> CloseableReader:
    return reader_

  /**
  Writes the given $data.
  May block, waiting for the reader.

  It is an error to close the reader without consuming all data that is written.
  */
  write data from/int = 0 to/int = data.size:
    return writer_.write data from to

  /**
  Closes the ReaderWriter for writing.
  */
  close -> none:
    writer_.writer_close

class ReaderWriterReader_ implements CloseableReader:
  helper_/ReaderWriterHelper_ ::= ?

  constructor .helper_:

  read -> ByteArray?:
    return helper_.read

  close -> none:
    helper_.reader_close

// This class could be combined with the ReaderWriter, if we had some other way
// than privacy to indicate which methods are synchronized.
monitor ReaderWriterHelper_:
  buffer_size_/int ::= ?
  buffer_/ByteArray := ?
  outgoing_ := null
  fullness_ := 0
  writer_closed_ := false
  reader_closed_ := false

  constructor .buffer_size_:
    buffer_ = ByteArray buffer_size_

  writer_close -> none:
    if fullness_ != 0:
      await: outgoing_ == null or reader_closed_
      outgoing_ = buffer_.copy 0 fullness_
    writer_closed_ = true

  reader_close -> none:
    reader_closed_ = true

  write data from/int to/int -> int:
    if writer_closed_: throw "CLOSED"
    result := to - from
    while from != to:
      await: fullness_ != buffer_.size or outgoing_ == null or reader_closed_
      if reader_closed_: throw "CLOSED"
      space := buffer_.size - fullness_
      if space == 0:
        assert: outgoing_ == null
        outgoing_ = buffer_
        buffer_ = ByteArray buffer_size_
        fullness_ = 0
        space = buffer_.size
      remaining := to - from
      chunk_size := min space remaining
      buffer_.replace fullness_ data from from + chunk_size
      from += chunk_size
      fullness_ += chunk_size
    return result

  read:
    await: outgoing_ or writer_closed_
    if outgoing_:
      result := outgoing_
      outgoing_ = null
      return result
    assert: writer_closed_
    return null
