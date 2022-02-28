// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import reader

/**
A lightweight writer wrapper that enhances the the user experience of the
  underlying writer.

The internal writer must have the following method: `write data -> int`
It can optionally have `close` and `close_writer`, which are transparently
  forwarded from the `Writer` to the internal writer.
*/
class Writer:
  writer_ := ?

  /** Constructs a writer */
  constructor .writer_:

  /** Writes everything provided by the $reader. */
  write_from reader/reader.Reader -> none:
    while data := reader.read: write data

  /**
  Writes the given $data.

  The internal writer might not be able to handle all of the data in one go. In
    that case, the method invokes the internal writer's `write` method multiple
    times until all data has been processed.
  If the internal writer has an error, it is not possible to see how much data was
    written. If it is necessary to know how much data was correctly written, then
    the internal writer must be used directly.
  */
  write data from/int=0 to/int=data.size:
    size := to - from
    while from < to:
      from += writer_.write data[from..to]
      if from != to: yield
    return size

  /**
  Closes the writer.
  The internal writer must have a `close_writer` method.
  */
  close_write -> none:
    writer_.close_write

  /**
  Closes the writer.
  The internal writer must have a `close` method.
  */
  close -> none:
    writer_.close
