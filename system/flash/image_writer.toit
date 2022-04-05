// Copyright (C) 2022 Toitware ApS.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

import uuid
import system.services show ServiceResource ServiceDefinition

import .allocation
import .reservation

IMAGE_WORD_SIZE  ::= BYTES_PER_WORD
IMAGE_CHUNK_SIZE ::= (BITS_PER_WORD + 1) * IMAGE_WORD_SIZE

class ContainerImageWriter extends ServiceResource:
  reservation_/FlashReservation? := ?
  image_/ByteArray ::= ?

  // We buffer the partial last chunk, because we have to write
  // the image in full chunks.
  partial_chunk_/ByteArray? := ByteArray IMAGE_CHUNK_SIZE
  partial_chunk_fill_/int := 0

  constructor service/ServiceDefinition client/int .reservation_:
    image_ = image_writer_create_ reservation_.offset reservation_.size
    super service client

  write data/ByteArray -> none:
    start := 0
    limit := data.size
    // If we have a partial chunk, we append to it. If it ends up being a full chunk,
    // we write it into flash and proceed with any additional data.
    if partial_chunk_fill_ > 0:
      missing := IMAGE_CHUNK_SIZE - partial_chunk_fill_
      if missing > limit:
        partial_chunk_.replace partial_chunk_fill_ data 0 limit
        partial_chunk_fill_ += limit
        return
      // We can fill the partial chunk completely, so we do that and
      // write it into flash. After that the partial chunk is empty.
      partial_chunk_.replace partial_chunk_fill_ data 0 missing
      image_writer_write_ image_ partial_chunk_ 0 IMAGE_CHUNK_SIZE
      partial_chunk_fill_ = 0
      start = missing
    // We have no proceeding partial chunk, so we cut off the extra bytes
    // at the end, so we can write all the full chunks that are available
    // and save the extra bytes for the next call to write.
    assert: partial_chunk_fill_ == 0
    extra := (limit - start) % IMAGE_CHUNK_SIZE
    if extra > 0:
      cutoff := limit - extra
      partial_chunk_.replace 0 data cutoff limit
      partial_chunk_fill_ = extra
      limit = cutoff
    // Write all the full chunks we can.
    List.chunk_up start limit IMAGE_CHUNK_SIZE: | from to |
      image_writer_write_ image_ data from to

  commit -> FlashAllocation:
    try:
      if partial_chunk_fill_ > 0: throw "Incomplete image"
      // TODO(kasper): Better uuid generation? Let user control?
      image_writer_commit_ image_ (uuid.uuid5 "programs" "$Time.monotonic_us").to_byte_array
      return FlashAllocation reservation_.offset
    finally:
      close

  on_closed -> none:
    reservation_.close
    reservation_ = null
    partial_chunk_ = null
    image_writer_close_ image_

// ----------------------------------------------------------------------------

image_writer_create_ offset size:
  #primitive.image.writer_create

image_writer_write_ image part/ByteArray from/int to/int:
  #primitive.image.writer_write

image_writer_commit_ image id/ByteArray:
  #primitive.image.writer_commit

image_writer_close_ image:
  #primitive.image.writer_close
