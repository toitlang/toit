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

import binary
import uuid
import system.services show ServiceResource ServiceDefinition

import .allocation
import .registry
import .reservation

IMAGE_WORD_SIZE  ::= BYTES_PER_WORD
IMAGE_CHUNK_SIZE ::= (BITS_PER_WORD + 1) * IMAGE_WORD_SIZE

relocate allocation/FlashAllocation registry/FlashRegistry -> FlashAllocation:
  assert: allocation.type == FLASH_ALLOCATION_PROGRAM_UNRELOCATED_TYPE
  size := binary.LITTLE_ENDIAN.uint32 allocation.metadata 0
  relocated_size ::= size - (size / IMAGE_CHUNK_SIZE) * IMAGE_WORD_SIZE
  reservation ::= registry.reserve relocated_size
  if reservation == null: throw "No space left in flash"
  image ::= image_writer_create_ reservation.offset reservation.size
  try:
    from ::= allocation.offset + FLASH_ALLOCATION_HEADER_SIZE
    to ::= from + size
    image_writer_write_all_ image from to
    image_writer_commit_ image allocation.id.to_byte_array
    return FlashAllocation reservation.offset
  finally:
    reservation.close
    if image: image_writer_close_ image

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
    List.chunk_up 0 data.size (IMAGE_CHUNK_SIZE - partial_chunk_fill_) IMAGE_CHUNK_SIZE: | from to size |
      if size == IMAGE_CHUNK_SIZE:
        assert: partial_chunk_fill_ == 0
        image_writer_write_ image_ data from to
      else:
        partial_chunk_.replace partial_chunk_fill_ data from to
        partial_chunk_fill_ += size
        if partial_chunk_fill_ == IMAGE_CHUNK_SIZE:
          image_writer_write_ image_ partial_chunk_ 0 IMAGE_CHUNK_SIZE
          partial_chunk_fill_ = 0

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

image_writer_write_all_ image from/int to/int:
  #primitive.image.writer_write_all

image_writer_commit_ image id/ByteArray:
  #primitive.image.writer_commit

image_writer_close_ image:
  #primitive.image.writer_close
