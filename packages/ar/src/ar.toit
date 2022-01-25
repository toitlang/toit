// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by an MIT-style license that can be
// found in the package's LICENSE file.

import bytes
import writer show Writer
import reader show Reader BufferedReader

AR_HEADER_ ::= "!<arch>\x0A"

FILE_NAME_OFFSET_ ::= 0
FILE_TIMESTAMP_OFFSET_ ::= 16
FILE_OWNER_ID_OFFSET_ ::= 28
FILE_GROUP_ID_OFFSET_ ::= 34
FILE_MODE_OFFSET_ ::= 40
FILE_BYTE_SIZE_OFFSET_ ::= 48
FILE_ENDING_CHARS_OFFSET_ ::= 58
FILE_HEADER_SIZE_ ::= 60

FILE_ENDING_CHARS_ ::= "\x60\x0A"

FILE_NAME_SIZE_ ::= FILE_TIMESTAMP_OFFSET_ - FILE_NAME_OFFSET_
FILE_TIMESTAMP_SIZE_ ::= FILE_OWNER_ID_OFFSET_ - FILE_TIMESTAMP_OFFSET_
FILE_OWNER_ID_SIZE_ ::= FILE_GROUP_ID_OFFSET_ - FILE_OWNER_ID_OFFSET_
FILE_GROUP_ID_SIZE_ ::= FILE_MODE_OFFSET_ - FILE_GROUP_ID_OFFSET_
FILE_MODE_SIZE_ ::= FILE_BYTE_SIZE_OFFSET_ - FILE_MODE_OFFSET_
FILE_BYTE_SIZE_SIZE_ ::= FILE_ENDING_CHARS_OFFSET_ - FILE_BYTE_SIZE_OFFSET_
FILE_ENDING_CHARS_SIZE_ ::= FILE_HEADER_SIZE_ - FILE_ENDING_CHARS_OFFSET_

PADDING_STRING_ ::= "\x0A"
PADDING_CHAR_ ::= '\x0A'

DETERMINISTIC_TIMESTAMP_ ::= 0
DETERMINISTIC_OWNER_ID_  ::= 0
DETERMINISTIC_GROUP_ID_  ::= 0
DETERMINISTIC_MODE_      ::= 0b110_100_100  // Octal 644.

/**
An 'ar' archiver.

Writes the given files into the writer in the 'ar' file format.
*/
class ArWriter:
  writer_ ::= ?

  constructor writer:
    writer_ = Writer writer
    write_ar_header_

  /**
  Adds a new "file" to the ar-archive.

  This function sets all file attributes to the same default values as are used
    by 'ar' when using the 'D' (deterministic) option. For example, the
    modification date is set to 0 (epoch time).
  */
  add name/string content -> none:
    if name.size > FILE_NAME_SIZE_: throw "Filename too long"
    write_ar_file_header_ name content.size
    writer_.write content
    if needs_padding_ content.size:
      writer_.write PADDING_STRING_

  /**
  Variant of $(add name content).
  Adds a new $ar_file to the ar-archive.
  */
  add ar_file/ArFile -> none:
    add ar_file.name ar_file.content

  write_ar_header_:
    writer_.write AR_HEADER_

  write_string_ str/string header/ByteArray offset/int size/int:
    for i := 0; i < size; i++:
      if i < str.size:
        header[offset + i] = str.at --raw i
      else:
        header[offset + i] = ' '

  write_number_ --base/int n/int header/ByteArray offset/int size/int:
    // For simplicity we write the number right to left and then shift
    // the computed values.
    i := size - 1
    for ; i >= 0; i--:
      header[offset + i] = '0' + n % base
      n = n / base
      if n == 0: break
    if n != 0: throw "OUT_OF_RANGE"
    // 'i' is the last entry where we wrote a significant digit.
    nb_digits := size - i
    number_offset := i
    header.replace offset header (offset + number_offset) (offset + size)
    // Pad the rest with spaces.
    for j := nb_digits; j < size; j++:
      header[offset + j] = ' '

  write_decimal_ n/int header/ByteArray offset/int size/int:
    write_number_ --base=10 n header offset size

  write_octal_ n/int header/ByteArray offset/int size/int:
    write_number_ --base=8 n header offset size

  write_ar_file_header_ name/string content_size/int:
    header := ByteArray FILE_HEADER_SIZE_
    write_string_ name
        header
        FILE_NAME_OFFSET_
        FILE_NAME_SIZE_
    write_decimal_ DETERMINISTIC_TIMESTAMP_
        header
        FILE_TIMESTAMP_OFFSET_
        FILE_TIMESTAMP_SIZE_
    write_decimal_ DETERMINISTIC_OWNER_ID_
        header
        FILE_OWNER_ID_OFFSET_
        FILE_OWNER_ID_SIZE_
    write_decimal_ DETERMINISTIC_GROUP_ID_
        header
        FILE_GROUP_ID_OFFSET_
        FILE_GROUP_ID_SIZE_
    write_octal_ DETERMINISTIC_MODE_
        header
        FILE_MODE_OFFSET_
        FILE_MODE_SIZE_
    write_decimal_ content_size
        header
        FILE_BYTE_SIZE_OFFSET_
        FILE_BYTE_SIZE_SIZE_
    write_string_ FILE_ENDING_CHARS_
        header
        FILE_ENDING_CHARS_OFFSET_
        FILE_ENDING_CHARS_SIZE_

    writer_.write header

  needs_padding_ size/int -> bool:
    return size & 1 == 1

class ArFile:
  name / string
  content / ByteArray

  constructor .name .content:

class ArFileOffsets:
  name / string
  from / int
  to   / int

  constructor .name .from .to:

class ArReader:
  reader_ / BufferedReader
  offset_ / int := 0

  constructor reader/Reader:
    reader_ = BufferedReader reader
    skip_header_

  constructor.from_bytes buffer/ByteArray:
    return ArReader (bytes.Reader buffer)

  /// Returns the next file in the archive.
  /// Returns null if none is left.
  next -> ArFile?:
    name := read_name_
    if not name: return null
    byte_size := read_byte_size_skip_ignored_header_
    content := read_content_ byte_size
    return ArFile name content

  /**
  Returns the next $ArFileOffsets, or `null` if no file is left.
  */
  next --offsets/bool -> ArFileOffsets?:
    if not offsets: throw "INVALID_ARGUMENT"
    name := read_name_
    if not name: return null
    byte_size := read_byte_size_skip_ignored_header_
    content_offset := offset_
    skip_content_ byte_size
    return ArFileOffsets name content_offset (content_offset + byte_size)

  /// Invokes the given $block on each $ArFile of the archive.
  do [block]:
    while file := next:
      block.call file

  /// Invokes the given $block on each $ArFileOffsets of the archive.
  do --offsets/bool [block]:
    if not offsets: throw "INVALID_ARGUMENT"
    while file_offsets := next --offsets:
      block.call file_offsets

  /**
  Finds the given $name file in the archive.
  Returns null if not found.
  This operation does *not* reset the archive. If files were skipped to
    find the given $name, then these files can't be read without creating
    a new $ArReader.
  */
  find name/string -> ArFile?:
    while true:
      file_name := read_name_
      if not file_name: return null
      byte_size := read_byte_size_skip_ignored_header_
      if file_name == name:
        content := read_content_ byte_size
        return ArFile name content
      skip_content_ byte_size

  /**
  Finds the given $name file in the archive.
  Returns null if not found.
  This operation does *not* reset the archive. If files were skipped to
    find the given $name, then these files can't be read without creating
    a new $ArReader.
  */
  find --offsets/bool name/string -> ArFileOffsets?:
    if not offsets: throw "INVALID_ARGUMENT"
    while true:
      file_name := read_name_
      if not file_name: return null
      byte_size := read_byte_size_skip_ignored_header_
      if file_name == name:
        file_offset := offset_
        skip_content_ byte_size
        return ArFileOffsets name file_offset (file_offset + byte_size)
      skip_content_ byte_size

  skip_header_:
    header := reader_read_string_ AR_HEADER_.size
    if header != AR_HEADER_: throw "Invalid Ar File"

  read_decimal_ size/int -> int:
    str := reader_read_string_ size
    result := 0
    for i := 0; i < str.size; i++:
      c := str[i]
      if c == ' ': return result
      else if '0' <= c <= '9': result = 10 * result + c - '0'
      else: throw "INVALID_AR_FORMAT"
    return result

  is_padded_ size/int: return size & 1 == 1

  read_name_ -> string?:
    if not reader_.can_ensure 1: return null
    name / string := reader_read_string_ FILE_NAME_SIZE_
    name = name.trim --right
    if name.ends_with "/": name = name.trim --right "/"
    return name

  read_byte_size_skip_ignored_header_ -> int:
    skip_count := FILE_TIMESTAMP_SIZE_
        + FILE_OWNER_ID_SIZE_
        + FILE_GROUP_ID_SIZE_
        + FILE_MODE_SIZE_
    reader_skip_ skip_count
    byte_size := read_decimal_ FILE_BYTE_SIZE_SIZE_
    ending_char1 := reader_read_byte_
    ending_char2 := reader_read_byte_
    if ending_char1 != FILE_ENDING_CHARS_[0] or ending_char2 != FILE_ENDING_CHARS_[1]:
      throw "INVALID_AR_FORMAT"
    return byte_size

  read_content_ byte_size/int -> ByteArray:
    content := reader_read_bytes_ byte_size
    if is_padded_ byte_size: reader_skip_ 1
    return content

  skip_content_ byte_size/int -> none:
    reader_skip_ byte_size
    if is_padded_ byte_size: reader_skip_ 1

  reader_read_string_ size/int -> string:
    result := reader_.read_string size
    offset_ += size
    return result

  reader_skip_ size/int -> none:
    reader_.skip size
    offset_ += size

  reader_read_byte_ -> int:
    result := reader_.read_byte
    offset_++
    return result

  reader_read_bytes_ size/int -> ByteArray:
    result := reader_.read_bytes size
    offset_ += size
    return result
