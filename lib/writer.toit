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
  May yield.
  */
  write data from/int=0 to/int=data.size:
    size := to - from
    while from < to:
      from += writer_.write data[from..to]
      if from != to:
        yield
        while data is string and from != to and data[from] == null:  // Not on a character boundary.
          // We can't slice a string at non-character boundaries.
          // If the `write` function only wrote parts of a character, we
          // extract the rest of the character as a byte array and write it
          // this way.  Uses `while` instead of `if` because even a 2-byte
          // byte array might not be written in one operation.
          cut_point := from + 1
          while cut_point != to and data[cut_point] == null:
            cut_point++
          // `to_byte_array` doesn't have an issue with character boundaries.
          snip := data.to_byte_array from cut_point
          from += writer_.write snip
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
