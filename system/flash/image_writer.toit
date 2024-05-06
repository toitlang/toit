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

import io show LITTLE-ENDIAN
import uuid
import system
import system.services show ServiceProvider ServiceResource

import .allocation
import .registry
import .reservation

IMAGE-WORD-SIZE  ::= system.BYTES-PER-WORD
IMAGE-CHUNK-SIZE ::= (system.BITS-PER-WORD + 1) * IMAGE-WORD-SIZE

class ContainerImageWriter extends ServiceResource:
  reservation_/FlashReservation? := ?
  image_/ByteArray ::= ?

  // We buffer the partial last chunk, because we have to write
  // the image in full chunks.
  partial-chunk_/ByteArray? := ByteArray IMAGE-CHUNK-SIZE
  partial-chunk-fill_/int := 0

  constructor provider/ServiceProvider client/int .reservation_:
    image_ = image-writer-create_ reservation_.offset reservation_.size
    super provider client

  write data/ByteArray -> none:
    List.chunk-up 0 data.size (IMAGE-CHUNK-SIZE - partial-chunk-fill_) IMAGE-CHUNK-SIZE: | from to size |
      if size == IMAGE-CHUNK-SIZE:
        assert: partial-chunk-fill_ == 0
        image-writer-write_ image_ data from to
      else:
        partial-chunk_.replace partial-chunk-fill_ data from to
        partial-chunk-fill_ += size
        if partial-chunk-fill_ == IMAGE-CHUNK-SIZE:
          image-writer-write_ image_ partial-chunk_ 0 IMAGE-CHUNK-SIZE
          partial-chunk-fill_ = 0

  commit --flags/int --data/int -> FlashAllocation:
    try:
      if partial-chunk-fill_ > 0: throw "Incomplete image"
      metadata := #[flags, 0, 0, 0, 0]
      LITTLE-ENDIAN.put-uint32 metadata 1 data
      image-writer-commit_ image_ metadata
      return FlashAllocation reservation_.offset
    finally:
      close

  on-closed -> none:
    reservation_.close
    reservation_ = null
    partial-chunk_ = null
    image-writer-close_ image_

// ----------------------------------------------------------------------------

image-writer-create_ offset size:
  #primitive.image.writer-create

image-writer-write_ image part/ByteArray from/int to/int:
  #primitive.image.writer-write

image-writer-commit_ image metadata/ByteArray:
  #primitive.image.writer-commit

image-writer-close_ image:
  #primitive.image.writer-close
