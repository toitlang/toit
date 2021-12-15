// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the package's LICENSE file.

import .file as file
import writer show Writer

/**
A tar archiver.

Writes the given files into the writer in tar file format.
*/
class Tar:
  writer_ ::= ?

  constructor writer:
    writer_ = Writer writer

  /**
  Adds a new "file" to the generated tar-archive.

  This function sets all file attributes to some default values. For example, the
    modification date is set to 0 (epoch time).
  */
  add file_name/string content -> none:
    add_ file_name content --type=normal_

  /**
  Closes the tar stream, and invokes `close_write` on the stored writer if $close_writer is true.
  */
  close --close_writer /bool = true:
    // TODO(florian): feels heavy to allocate a new array just to write a bunch of zeroes.
    zero_header := ByteArray 512
    writer_.write zero_header
    writer_.write zero_header
    if close_writer: writer_.close_write

  /**
  Adds the given $file_name with its $content to the tar stream.

  The additional $type parameter is used when filenames don't fit in the standard
    header, and the "LongLink" technique stores the filename as file content.
  The $type parameter must be one of the constants below: $normal_ or $long_link_.
  */
  add_ file_name/string content --type/int -> none:
    if file_name.size > 100:
      // The file-name is encoded a separate "file".
      add_ "././@LongLink" file_name --type=long_link_
      file_name = file_name.copy 0 100

    file_size := content.size
    file_size_in_octal := file_size.stringify 8

    header := ByteArray 512
    // See https://en.wikipedia.org/wiki/Tar_(computing)#File_format for the format.
    header.replace 0 file_name.to_byte_array
    header.replace 100 "0000664".to_byte_array
    header.replace 124 file_size_in_octal.to_byte_array
    // The checksum is computed using spaces. Later it is replaced with the actual values.
    header.replace 148 "        ".to_byte_array
    header[156] = type
    header.replace 257 "ustar  ".to_byte_array

    checksum := 0
    for i := 0; i < 512; i++:
      checksum += header[i]
    checksum_in_octal := checksum.stringify 8
    // Quoting Wikipedia: [The checksum] is stored as a six digit octal number with
    //   leading zeroes followed by a NUL and then a space.
    checksum_pos := 148
    for i := 0; i < 6 - checksum_in_octal.size; i++:
      header[checksum_pos++] = '0'
    header.replace checksum_pos checksum_in_octal.to_byte_array
    header[148 + 6] = '\0'
    header[148 + 7] = ' '

    writer_.write header
    writer_.write content
    // Fill up with zeroes to the next 512 boundary.
    last_chunk_size := file_size % 512
    if last_chunk_size != 0:
      missing := 512 - last_chunk_size
      // Reuse the header, to avoid allocating another object.
      // Still need to zero it out.
      for i := 0; i < missing; i++:
        header[i] = '\0'
      writer_.write header 0 missing

  static normal_    ::= '0'
  static long_link_ ::= 'L'

// Just a small test/example.
main:
  tar := Tar (file.Stream "/tmp/toit.tar" file.CREAT | file.WRONLY 0x1ff)
  tar.add "test2.txt" "456\n"
  tar.add "012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789" "123\n"
  tar.close
