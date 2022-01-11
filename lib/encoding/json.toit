// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import reader show Reader
import fixed_point show FixedPoint

INITIAL_BUFFER_SIZE_ ::= 64
MAX_BUFFER_GROWTH_ ::= 1024


/**
Encodes the $obj as a JSON ByteArray.
The $obj must be null or an instance of int, bool, float, string, List, or Map.
  Maps must have only string keys.  The elements of lists and the values of
  maps can be any of the above supported types.
Utf-8 encoding is used for strings.
*/
encode obj -> ByteArray:
  e := Encoder
  e.encode obj
  return e.to_byte_array

/**
Decodes the $bytes, which is a ByteArray in JSON format.
The result is null or an instance of int, bool, float, string, List, or Map.
  The list elements and map values will also be one of these types.
*/
decode bytes/ByteArray -> any:
  d := Decoder
  return d.decode bytes

/**
Encodes the $obj as a JSON string.
The $obj must be null or an instance of int, bool, float, string, List, or Map.
  Maps must have only string keys.  The elements of lists and the values of
  maps can be any of the above supported types.
*/
stringify obj/any -> string:
  e := Encoder
  e.encode obj
  return e.to_string

/**
Decodes the $str, which is a string in JSON format.
The result is null or an instance of of int, bool, float, string, List, or Map.
  The list elements and map values will also be one of these types.
*/
parse str/string:
  d := Decoder
  // size --runes is a highly optimized way to find the number of code points in a string.
  if str.size == (str.size --runes):
    return d.decode str
  // String contains non-ASCII UTF-8 characters, so we have to use a shim that
  // makes the string more like a ByteArray.
  return d.decode (StringView_ str)

decode_stream reader/Reader:
  d := StreamingDecoder
  return d.decode_stream reader

class Buffer_:
  buffer_ := ByteArray INITIAL_BUFFER_SIZE_
  offset_ := 0

  to_string:
    return buffer_.to_string 0 offset_

  to_byte_array:
    return buffer_.copy 0 offset_

  ensure_ size -> none:
    if offset_ + size <= buffer_.size: return
    new_size := buffer_.size * 2
    while new_size < offset_ + size:
      new_size *= 2
    new := ByteArray new_size
    new.replace 0 buffer_
    buffer_ = new

  put_string_ str:
    len := str.size
    ensure_ len
    buffer_.replace offset_ str
    offset_ += len

  put_string_ str from to:
    len := to - from
    ensure_ len
    buffer_.replace offset_ str from to
    offset_ += len

  put_byte_ byte:
    ensure_ 1
    buffer_[offset_++] = byte

  clear_:
    offset_ = 0

class Encoder extends Buffer_:
  encode obj/any:
    if obj is string: encode_string_ obj
    else if obj is num: encode_number_ obj
    else if obj is FixedPoint: encode_number_ obj
    else if identical obj true: encode_true_
    else if identical obj false: encode_false_
    else if identical obj null: encode_null_
    else if obj is Map: encode_map_ obj
    else if obj is List: encode_list_ obj
    else: throw "INVALID_JSON_OBJECT"

  encode_string_ str:
    size := str.size
    ensure_ str.size + 2

    put_byte_ '"'

    offset := 0
    for i := 0; i < size; i++:
      c := str.at --raw i
      // Backlash is the largest special character we need to consider,
      // so start by checking for that.
      if '\\' < c: continue
      if c < 32:
        // Handle control characters.
        if i > offset: put_string_ str offset i
        offset = i + 1
        put_byte_ '\\'
        if c == '\b':
          put_byte_ 'b'
        else if c == '\f':
          put_byte_ 'f'
        else if c == '\n':
          put_byte_ 'n'
        else if c == '\r':
          put_byte_ 'r'
        else if c == '\t':
          put_byte_ 't'
        else:
          put_unicode_escape_ c
      else if c == '"' or c == '\\':
        // And finally handle double-quotes and backslash.
        if i > offset: put_string_ str offset i
        offset = i + 1
        put_byte_ '\\'
        put_byte_ c

    if offset < size: put_string_ str offset size

    put_byte_ '"'

  encode_number_ number:
    str := number is float ? number.stringify 2 : number.stringify
    put_string_ str

  encode_true_:
    put_string_ "true"

  encode_false_:
    put_string_ "false"

  encode_null_:
    put_string_ "null"

  encode_map_ map:
    put_byte_ '{'

    first := true
    map.do: |key value|
      if not first: put_byte_ ','
      first = false
      if key is not string:
        throw "INVALID_JSON_OBJECT"
      encode_string_ key
      put_byte_ ':'
      encode value

    put_byte_ '}'

  encode_list_ list:
    put_byte_ '['

    for i := 0; i < list.size; i++:
      if i > 0: put_byte_ ','
      encode list[i]

    put_byte_ ']'

  put_unicode_escape_ code_point/int:
    put_byte_ 'u'
    put_byte_
      _hex_digit (code_point >> 12) & 0xf
    put_byte_
      _hex_digit (code_point >> 8) & 0xf
    put_byte_
      _hex_digit (code_point >> 4) & 0xf
    put_byte_
      _hex_digit code_point & 0xf


_hex_digit x: return x < 10 ? '0' + x : 'a' + x - 10

class Decoder:
  bytes_ := null
  offset_ := 0
  tmp_buffer_ ::= Buffer_
  utf_8_buffer_/ByteArray? := null
  seen_strings_/Set? := null
  reader_/Reader? := null
  static MAX_DEDUPED_STRING_SIZE_ ::= 128
  static MAX_DEDUPED_STRINGS_ ::= 128

  decode bytes -> any:
    bytes_ = bytes
    offset_ = 0
    seen_strings_ = {}

    return decode_

  decode_:
    offset_ = skip_whitespaces_ bytes_ offset_
    c := bytes_[offset_]
    if c == '"': return decode_string_
    else if c == '{': return decode_map_
    else if c == '[': return decode_list_
    else if c == 't': return decode_true_
    else if c == 'f': return decode_false_
    else if c == 'n': return decode_null_
    else if c == '-' or '0' <= c <= '9': return decode_number_
    else: throw "INVALID_JSON_CHARACTER"

  // Gets the hash of a string that contains no backslashes and ends
  // at the next double quote character.  Returns -1 if this is too
  // difficult.
  static hash_simple_string_ bytes offset -> int:
    #primitive.core.hash_simple_json_string:
      return -1

  // Uses blob_index_of primitive to get the size of a string that ends at the
  // next double quote character.  We know from hash_simple_string_ that there
  // are no backslash-escapes before the closing double quote.
  static end_of_json_string_ bytes character offset end -> int:
    #primitive.core.blob_index_of

  // Compares the found string (from the set) with the bytes in
  // the buffer, terminated by a double quote.
  static compare_simple_string_ bytes offset found/string -> bool:
    #primitive.core.compare_simple_json_string

  decode_string_:
    expect_ '"'

    hash := hash_simple_string_ bytes_ offset_
    if hash == -1:
      return slow_decode_string_

    result := null
    seen_strings_.get_by_hash_ hash
      --initial=:
        length := (end_of_json_string_ bytes_ '"' offset_ bytes_.size) - offset_
        result = bytes_.to_string offset_ offset_ + length
        offset_ += length + 1
        // Don't put huge strings in the cache, and don't grow it when it has
        // likely seen all the repeated key strings.
        put_in_set := result.size <= MAX_DEDUPED_STRING_SIZE_ and seen_strings_.size < MAX_DEDUPED_STRINGS_
        put_in_set ? result : null
      --compare=: | found |
        if compare_simple_string_ bytes_ offset_ found:
          offset_ += found.size + 1
          return found
        false
    return result

  slow_decode_string_:
    buffer := tmp_buffer_
    buffer.clear_
    bytes_size := bytes_.size
    while true:
      if offset_ >= bytes_size: throw "UNTERMINATED_JSON_STRING"

      c := bytes_[offset_]

      if c == '"':
        break
      else if c == '\\':
        offset_++
        c = bytes_[offset_]
        if      c == 'b': c = '\b'
        else if c == 'f': c = '\f'
        else if c == 'n': c = '\n'
        else if c == 'r': c = '\r'
        else if c == 't': c = '\t'
        else if c == 'u':
          offset_++
          // Read 4 hex digits.
          if offset_ + 4 > bytes_size: throw "UNTERMINATED_JSON_STRING"
          c = read_four_hex_digits_
          if 0xd800 <= c <= 0xdbff:
            // First part of a surrogate pair.
            if offset_ + 6 > bytes_size: throw "UNTERMINATED_JSON_STRING"
            if bytes_[offset_] != '\\' or bytes_[offset_ + 1] != 'u': throw "UNPAIRED_SURROGATE"
            offset_ += 2
            part_2 := read_four_hex_digits_
            if not 0xdc00 <= part_2 <= 0xdfff: throw "INVALID_SURROGATE_PAIR"
            c = 0x10000 + ((c & 0x3ff) << 10) | (part_2 & 0x3ff)
          buf_8 := utf_8_buffer_
          if not buf_8:
            utf_8_buffer_ = ByteArray 4
            buf_8 = utf_8_buffer_
          bytes := utf_8_bytes c
          write_utf_8_to_byte_array buf_8 0 c
          bytes.repeat:
            buffer.put_byte_ buf_8[it]
          continue

      buffer.put_byte_ c
      offset_++

    offset_++
    result := buffer.to_string
    if seen_strings_.size >= MAX_DEDUPED_STRINGS_ or result.size > MAX_DEDUPED_STRING_SIZE_:
      return result
    return seen_strings_.get_by_hash_ result.hash_code
      --initial=: result
      --compare=: | found | found == result

  read_four_hex_digits_ -> int:
    hex_value := 0
    4.repeat:
      hex_digit := bytes_[offset_++]
      // Lower case the character.
      if 'A' <= hex_digit <= 'Z': hex_digit -= 'A' - 'a'
      // Add the digit to the value.
      hex_value <<= 4
      if '0' <= hex_digit <= '9':      hex_value += hex_digit - '0'
      else if 'a' <= hex_digit <= 'f': hex_value += hex_digit - 'a' + 10
      else: throw "BAD \\u ESCAPE IN JSON STRING"
    return hex_value

  decode_map_:
    expect_ '{'

    map := {:}

    while true:
      checkpoint := offset_

      error := catch:
        offset_ = skip_whitespaces_ bytes_ offset_

        if bytes_[offset_] == '}': break

        if map.size > 0: expect_ ','

        offset_ = skip_whitespaces_ bytes_ offset_
        key := decode_string_

        offset_ = skip_whitespaces_ bytes_ offset_
        expect_ ':'

        value := decode_
        map[key] = value

      if error != null: handle_error_ error checkpoint

    offset_++
    return map

  decode_list_:
    expect_ '['

    list := []

    while true:
      checkpoint := offset_

      error := catch:
        offset_ = skip_whitespaces_ bytes_ offset_

        if bytes_[offset_] == ']': break

        if list.size > 0: expect_ ','

        value := decode_
        list.add value

      if error != null: handle_error_ error checkpoint

    offset_++
    return list

  // Overridden by StreamingDecoder
  handle_error_ error checkpoint/int -> none:
    throw error

  // An int used as a 32-entry bitmap that distinguishes between
  // characters that can continue a number and characters that
  // can terminate a number.  See explanation in the primitive code.
  static NUMBER_TABLE ::= 0x3ff6820
  // A bitmap that identifies which characters indicate a floating
  // point number.  Those characters are '.', 'e', and 'E'.
  static FLOAT_TABLE  ::=    0x4020

  static simple_size_of_number bytes offset -> int:
    #primitive.core.size_of_json_number:
      is_float := 0
      o := offset + 1
      for ; o < bytes.size; o++:
        c := bytes[o]
        // Unicode characters can't be part of a number.  Carriage return is
        // misidentified as a continuation of a number by the bitmap and must
        // be handled specially.
        if c == null or c == '\r': break
        if (NUMBER_TABLE >> (c & 0x1f)) & 1 == 0: break
        is_float |= (FLOAT_TABLE >> (c & 0x1f)) & 1
      return is_float == 1 ? -o : o

  decode_number_:
    o/int := simple_size_of_number bytes_ offset_
    start := offset_
    offset_ = o.abs
    // If the number ends at the end of the buffer we need to read more to
    // see if it continues in the next byte array.
    if offset_ == bytes_.size and reader_: throw "UNEXPECTED_END_OF_INPUT"

    data := bytes_ is StringView_ ? bytes_.str_ : bytes_
    if o < 0: return float.parse_ data start -o
    return int.parse_ data start o --on_error=: throw it

  decode_true_:
    "true".do: expect_ it
    return true

  decode_false_:
    "false".do: expect_ it
    return false

  decode_null_:
    "null".do: expect_ it
    return null

  expect_ byte:
    if bytes_[offset_++] != byte: throw "INVALID_JSON_CHARACTER"

  static skip_whitespaces_ bytes offset -> int:
    #primitive.core.json_skip_whitespace:
      while offset < bytes.size:
        c := bytes[offset]
        if c != ' ' and c != '\n' and c != '\t' and c != '\r':
          return offset
        offset++
      return offset

class StreamingDecoder extends Decoder:
  decode_stream reader/Reader -> any:
    reader_ = reader
    seen_strings_ = {}
    // Skip whitespace to get to the first data, which might be
    // a top-level number.
    while true:
      offset_ = 0
      bytes_ = reader.read
      if not bytes_: throw "EMPTY_READER"
      offset_ = Decoder.skip_whitespaces_ bytes_ offset_
      if offset_ != bytes_.size:
        break
    c := bytes_[offset_]
    if c == '-' or '0' <= c <= '9':
      // Top level number is a tricky case for the reader-based
      // JSON parser.  This is the only case where a number can
      // end at the end of the file.  Normally if a number ends
      // at the end of a file then we should read more data from
      // the reader to see if it continues.  Numbers are not
      // terminated in a visible way.  To solve this, read the
      // whole stream - it can't be so big if it consists of one
      // number.
      while get_more_:
        // Slurp up whole stream.
      reader_ = null  // Use non-incremental parsing.

    while true:
      error := catch:
        return decode_
      if error is WrappedException_:
        throw error.inner
      offset_ = 0
      if false == get_more_:
        throw error

  // Returns true if we ran out of input.
  get_more_ -> bool:
    if not reader_: return false
    old_bytes := bytes_
    next_bytes := #[]
    while next_bytes.size == 0:
      error := catch:
        next_bytes = reader_.read
      if error:
        throw
          WrappedException_ error
      if not next_bytes: return false
    bytes_ = old_bytes + next_bytes
    return true

  handle_error_ error checkpoint/int -> none:
    if error is WrappedException_: throw error
    bytes_ = bytes_[checkpoint..]
    offset_ = 0
    if false == get_more_:
      throw error
    offset_ = Decoder.skip_whitespaces_ bytes_ offset_

class StringView_:
  str_ ::= ?

  constructor .str_:

  operator [] i:
    return str_.at --raw i

  operator [..] --from=0 --to=size:
    return StringView_ str_[from..to]

  to_string from to:
    return str_.copy from to

  size:
    return str_.size

class WrappedException_:
  inner ::= ?

  constructor .inner:
