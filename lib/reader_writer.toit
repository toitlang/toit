// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import io

import reader show CloseableReader
/**
Support for inter task reading and writing.
*/

/**
A shim that allows one task to have a read interface and the other
  task to have a blocking write interface.  Implements $write.

Deprecated.
*/
class ReaderWriter:
  writer_/ReaderWriterHelper_ ::= ?
  reader_/CloseableReader ::= ?

  /**
  Constructs a reader-writer.

  The $buffer-size determines the size of the communication buffer.
  */
  constructor buffer-size/int=64:
    writer_ = ReaderWriterHelper_ buffer-size
    reader_ = ReaderWriterReader_ writer_

  /** The corresponding $CloseableReader. */
  reader -> CloseableReader:
    return reader_

  /**
  Writes the given $data.
  May block, waiting for the reader.

  It is an error to close the reader without consuming all data that is written.
  */
  write data/io.Data from/int = 0 to/int = data.byte-size:
    return writer_.write data from to

  /**
  Closes the ReaderWriter for writing.
  */
  close -> none:
    writer_.writer-close

class ReaderWriterReader_ implements CloseableReader:
  helper_/ReaderWriterHelper_ ::= ?

  constructor .helper_:

  read -> ByteArray?:
    return helper_.read

  close -> none:
    helper_.reader-close

// This class could be combined with the ReaderWriter, if we had some other way
// than privacy to indicate which methods are synchronized.
monitor ReaderWriterHelper_:
  buffer-size_/int ::= ?
  buffer_/ByteArray
  fullness_ := 0
  writer-closed_ := false
  reader-closed_ := false

  constructor .buffer-size_:
    buffer_ = ByteArray buffer-size_

  writer-close -> none:
    writer-closed_ = true

  reader-close -> none:
    reader-closed_ = true

  write data/io.Data from/int to/int -> int:
    if writer-closed_: throw "CLOSED"
    result := to - from
    while from != to:
      await: fullness_ != buffer_.size or reader-closed_
      if reader-closed_: throw "CLOSED"
      space := buffer_.size - fullness_
      remaining := to - from
      chunk-size := min space remaining
      // Put as much as possible into the buffer.
      // If we fill it up entirely, then the 'await' above will make us
      // wait until a reader empties the buffer.
      buffer_.replace fullness_ data from from + chunk-size
      from += chunk-size
      fullness_ += chunk-size
    return result

  read:
    await: fullness_ != 0 or writer-closed_
    result := ?
    if fullness_ != 0:
      result = buffer_.copy 0 fullness_
      fullness_ = 0
      return result
    assert: writer-closed_
    return null
