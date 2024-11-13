// Copyright (C) 2024 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .buffer
import .byte-order
import .data
import .reader
import .writer

export *

/**
The Toit IO library.

This library provides classes and functions for manipulating binary data.
Use $Reader and $Writer to read and write binary data, and $Buffer to
  accumulate data.
*/

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
