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

// Private support methods.
image_reader_create_ snapshot:
  #primitive.snapshot.reader_create

image_reader_size_in_bytes_ image:
  #primitive.snapshot.reader_size_in_bytes

image_reader_read_ image:
  #primitive.snapshot.reader_read

image_reader_close_ image:
  #primitive.snapshot.reader_close
