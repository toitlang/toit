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

  // TODO(kasper): Start writing out as soon as we can.
  buffer_/ByteArray := ByteArray 0

  constructor service/ServiceDefinition client/int .reservation_:
    image_ = image_writer_create_ reservation_.offset reservation_.size
    super service client

  write data/ByteArray -> none:
    // TODO(kasper): Start writing out sooner.
    buffer_ += data

  commit -> FlashAllocation:
    List.chunk_up 0 buffer_.size IMAGE_CHUNK_SIZE: | from to |
      image_writer_write_ image_ buffer_ from to
    // TODO(kasper): Better uuid generation? Let user control?
    image_writer_commit_ image_ (uuid.uuid5 "programs" "$Time.monotonic_us").to_byte_array
    result := FlashAllocation reservation_.offset
    close
    return result

  on_closed -> none:
    reservation_.close
    reservation_ = null
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
