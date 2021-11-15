// Copyright (C) 2018 Toitware ApS.
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

// API for reading a relocatable program image in chunks.
class ImageReader:
  content_ := ?

  // Takes a snapshot (a ByteArray), generates an image from the snapshot.
  constructor snapshot:
    content_ = image_reader_create_ snapshot

  // Returns the size of the image.
  size_in_bytes:
    return image_reader_size_in_bytes_ content_

  // Reads a block of the relocatable image stream
  // and returns the content in a ByteArray.
  read:
    return image_reader_read_ content_

  // Close the image read by deallocating image and auxiliary data structures.
  close:
    image_reader_close_ content_
    content_ = null

// API for writing a relocatable program image in chunks.
class ImageWriter:
  content_ := ?
  offset_ ::= ?

  constructor .offset_ size_in_bytes:
    content_ = image_writer_create_ offset_ size_in_bytes

  write part/ByteArray from to -> none:
    image_writer_write_ content_ part from to

  commit id/ByteArray -> none:
    image_writer_commit_ content_ id

  close -> none:
    image_writer_close_ content_


// Private support methods.
image_reader_create_ snapshot:
  #primitive.snapshot.reader_create

image_reader_size_in_bytes_ image:
  #primitive.snapshot.reader_size_in_bytes

image_reader_read_ image:
  #primitive.snapshot.reader_read

image_reader_close_ image:
  #primitive.snapshot.reader_close

image_writer_create_ offset size_in_bytes:
  #primitive.image.writer_create

image_writer_write_ image part/ByteArray from/int to/int:
  #primitive.image.writer_write

image_writer_commit_ image id/ByteArray:
  #primitive.image.writer_commit

image_writer_close_ image:
  #primitive.image.writer_close
