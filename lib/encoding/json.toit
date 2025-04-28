// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import io
import reader show Reader BufferedReader
import .json-like-encoder_

MAX-BUFFER-GROWTH_ ::= 1024

/**
Variant of $(encode obj).
If the $obj is or contains a non-supported type, then the converter
  block is called with the object and an instance of the $Encoder class.
  The converter is not called for map keys, which must still be strings.
The $converter block is passed an object to be serialized and an instance
  of the $Encoder class.  If it returns a non-null value, that value will
  be serialized instead of the object that was passed in.  Alternatively,
  the $converter block can call the $Encoder.encode, $Encoder.put-list,
  or $Encoder.put-unquoted methods on the encoder.
*/
encode obj [converter] -> ByteArray:
  buffer := io.Buffer
  e := Encoder.private_ buffer
  e.encode obj converter
  return buffer.bytes

/**
Variant of $(encode obj [converter]).
Takes a $Lambda instead of a block as $converter.
*/
encode obj converter/Lambda -> ByteArray:
  return encode obj: | obj encoder | converter.call obj encoder

/**
Encodes the $obj as a JSON ByteArray.
The $obj must be a supported type, which means null, or an instance of int,
  bool, float, string, List or Map.
Maps must have only string keys.  The elements of lists and the values of
  maps can be any of the above supported types.
UTF-8 encoding is used for strings.
*/
encode obj -> ByteArray:
  return encode obj: throw "INVALID_JSON_OBJECT"

/**
Variant of $(encode-stream --writer obj).
If the $obj is or contains a non-supported type, then the converter
  block is called with the object and an instance of the $Encoder class.
  The converter is not called for map keys, which must still be strings.
The $converter block is passed an object to be serialized and an instance
  of the $Encoder class.  If it returns a non-null value, that value will
  be serialized instead of the object that was passed in.  Alternatively,
  the $converter block can call the $Encoder.encode, $Encoder.put-list,
  or $Encoder.put-unquoted methods on the encoder.
*/
encode-stream --writer/io.Writer obj [converter] -> none:
  e := Encoder.private_ writer
  e.encode obj converter

/**
Variant of $(encode-stream --writer obj [converter]).
Takes a $Lambda instead of a block as $converter.
*/
encode-stream --writer/io.Writer obj converter/Lambda -> none:
  encode-stream --writer=writer obj: | obj encoder | converter.call obj encoder

/**
Encodes the $obj onto an $io.Writer in JSON format.
The $obj must be a supported type, which means null, or an instance of int,
  bool, float, string, List or Map.
Maps must have only string keys.  The elements of lists and the values of
  maps can be any of the above supported types.
UTF-8 encoding is used on the writer.
*/
encode-stream --writer/io.Writer obj -> none:
  encode-stream --writer=writer obj: throw "INVALID_JSON_OBJECT"

/**
Decodes the $bytes, which is a ByteArray in JSON format.
The result is null, or an instance of int, bool, float, string, List, or Map.
  The list elements and map values will also be one of these types.
*/
decode bytes/ByteArray -> any:
  d := Decoder
  return d.decode bytes

/**
Variant of $(stringify obj).
If the $obj is or contains a non-supported type, then the converter
  block is called with the object and an instance of the $Encoder class.
  The converter is not called for map keys, which must still be strings.
The $converter block is passed an object to be serialized and an instance
  of the $Encoder class.  If it returns a non-null value, that value will
  be serialized instead of the object that was passed in.  Alternatively,
  the $converter block can call the $Encoder.encode, $Encoder.put-list,
  or $Encoder.put-unquoted methods on the encoder.
*/
stringify obj/any [converter] -> string:
  buffer := io.Buffer
  e := Encoder.private_ buffer
  e.encode obj converter
  return buffer.to-string

/**
Variant of $(stringify obj [converter]).
Takes a $Lambda instead of a block as $converter.
*/
stringify obj converter/Lambda -> string:
  return stringify obj: | obj encoder | converter.call obj encoder

/**
Encodes the $obj as a JSON string.
The $obj must be a supported type, which means null, or an instance of int,
  bool, float, string, List or Map.
Maps must have only string keys.  The elements of lists and the values of
  maps can be any of the above supported types.
*/
stringify obj/any -> string:
  return stringify obj: throw "INVALID_JSON_OBJECT"

/**
Decodes the $str, which is a string in JSON format.
The result is null, or an instance of of int, bool, float, string, List, or Map.
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

/// $reader can be either an io.Reader, $Reader or a $BufferedReader.
/// Supportfor $Reader and $BufferedReader will be removed in the future.
decode-stream reader:
  d := StreamingDecoder
  return d.decode-stream reader

class Encoder extends EncoderBase_:
  /**
  Deprecated.  Use the top-level json.encode functions instead.
  Returns an encoder that encodes into an internal buffer.  The
    result can be extracted with $to-string or $to-byte-array.
  */
  constructor:
    super io.Buffer

  /**
  Returns an encoder that encodes onto an $io.Writer.
  */
  constructor.private_ writer/io.Writer:
    super writer

  /** See $EncoderBase_.encode */
  // TODO(florian): Remove when toitdoc compile understands inherited methods
  encode obj/any converter/Lambda:
    return super obj converter

  /** See $EncoderBase_.put-unquoted */
  // TODO(florian): Remove when toitdoc compile understands inherited methods
  put-unquoted data -> none:
    super data

  encode-string_ str:
    escaped := escape-string str
    size := escaped.size
    writer_.write-byte '"'
    writer_.write escaped
    writer_.write-byte '"'

  encode-number_ number:
    str := number is float ? number.stringify 2 : number.stringify
    writer_.write str

  encode-true_:
    writer_.write "true"

  encode-false_:
    writer_.write "false"

  encode-null_:
    writer_.write "null"

  encode-map_ map [converter]:
    writer_.write-byte '{'

    first := true
    map.do: |key value|
      if not first: writer_.write-byte ','
      first = false
      if key is not string:
        throw "INVALID_JSON_OBJECT"
      encode-string_ key
      writer_.write-byte ':'
      encode value converter

    writer_.write-byte '}'

  encode-list_ list [converter]:
    put-list list.size (: list[it]) converter

  /**
  Outputs a list-like thing to the JSON stream.
  This can be used by converter blocks.
  The generator is called repeatedly with indices from 0 to size - 1.
  */
  put-list size/int [generator] [converter]:
    writer_.write-byte '['

    for i := 0; i < size; i++:
      if i > 0: writer_.write-byte ','
      encode (generator.call i) converter

    writer_.write-byte ']'

class Decoder:
  bytes_ := null
  offset_ := 0
  tmp-buffer_ ::= io.Buffer
  utf-8-buffer_/ByteArray? := null
  seen-strings_/Set? := null
  buffered-reader_/io.Reader? := null
  static MAX-DEDUPED-STRING-SIZE_ ::= 128
  static MAX-DEDUPED-STRINGS_ ::= 128

  decode bytes -> any:
    bytes_ = bytes
    offset_ = 0
    seen-strings_ = {}

    result := decode_
    offset_ = skip-whitespaces_ bytes_ offset_
    if offset_ != bytes.size: throw "INVALID_JSON_CHARACTER"
    return result

  decode_:
    offset_ = skip-whitespaces_ bytes_ offset_
    c := bytes_[offset_]
    if c == '"': return decode-string_
    else if c == '{': return decode-map_
    else if c == '[': return decode-list_
    else if c == 't': return decode-true_
    else if c == 'f': return decode-false_
    else if c == 'n': return decode-null_
    else if c == '-' or '0' <= c <= '9': return decode-number_
    else: throw "INVALID_JSON_CHARACTER"

  // Gets the hash of a string that contains no backslashes and ends
  // at the next double quote character.  Returns -1 if this is too
  // difficult.
  static hash-simple-string_ bytes offset -> int:
    #primitive.core.hash-simple-json-string:
      return -1

  // Uses blob_index_of primitive to get the size of a string that ends at the
  // next double quote character.  We know from hash_simple_string_ that there
  // are no backslash-escapes before the closing double quote.
  static end-of-json-string_ bytes character offset end -> int:
    #primitive.core.blob-index-of

  // Compares the found string (from the set) with the bytes in
  // the buffer, terminated by a double quote.
  static compare-simple-string_ bytes offset found/string -> bool:
    #primitive.core.compare-simple-json-string

  decode-string_:
    expect_ '"'

    hash := hash-simple-string_ bytes_ offset_
    if hash == -1:
      return slow-decode-string_

    result := null
    seen-strings_.get-by-hash_ hash
      --initial=:
        length := (end-of-json-string_ bytes_ '"' offset_ bytes_.size) - offset_
        result = bytes_.to-string offset_ offset_ + length
        offset_ += length + 1
        // Don't put huge strings in the cache, and don't grow it when it has
        // likely seen all the repeated key strings.
        put-in-set := result.size <= MAX-DEDUPED-STRING-SIZE_ and seen-strings_.size < MAX-DEDUPED-STRINGS_
        put-in-set ? result : null
      --compare=: | found |
        if compare-simple-string_ bytes_ offset_ found:
          offset_ += found.size + 1
          return found
        false
    return result

  slow-decode-string_:
    buffer := tmp-buffer_
    buffer.clear
    bytes-size := bytes_.size
    while true:
      if offset_ >= bytes-size: throw "UNTERMINATED_JSON_STRING"

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
          if offset_ + 4 > bytes-size: throw "UNTERMINATED_JSON_STRING"
          c = read-four-hex-digits_
          if 0xd800 <= c <= 0xdbff:
            // First part of a surrogate pair.
            if offset_ + 6 > bytes-size: throw "UNTERMINATED_JSON_STRING"
            if bytes_[offset_] != '\\' or bytes_[offset_ + 1] != 'u': throw "UNPAIRED_SURROGATE"
            offset_ += 2
            part-2 := read-four-hex-digits_
            if not 0xdc00 <= part-2 <= 0xdfff: throw "INVALID_SURROGATE_PAIR"
            c = 0x10000 + ((c & 0x3ff) << 10) | (part-2 & 0x3ff)
          buf-8 := utf-8-buffer_
          if not buf-8:
            utf-8-buffer_ = ByteArray 4
            buf-8 = utf-8-buffer_
          bytes := utf-8-bytes c
          write-utf-8-to-byte-array buf-8 0 c
          buffer.write buf-8 0 bytes
          continue

      buffer.write-byte c
      offset_++

    offset_++
    result := buffer.to-string
    if seen-strings_.size >= MAX-DEDUPED-STRINGS_ or result.size > MAX-DEDUPED-STRING-SIZE_:
      return result
    return seen-strings_.get-by-hash_ result.hash-code
      --initial=: result
      --compare=: | found | found == result

  read-four-hex-digits_ -> int:
    hex-value := 0
    4.repeat:
      hex-value <<= 4
      hex-value += hex-char-to-value bytes_[offset_++] --on-error=(: throw "BAD \\u ESCAPE IN JSON STRING")
    return hex-value

  decode-map_:
    expect_ '{'

    map := {:}

    while true:
      checkpoint := offset_

      error := catch:
        offset_ = skip-whitespaces_ bytes_ offset_

        if bytes_[offset_] == '}': break

        if map.size > 0: expect_ ','

        offset_ = skip-whitespaces_ bytes_ offset_
        key := decode-string_

        offset_ = skip-whitespaces_ bytes_ offset_
        expect_ ':'

        value := decode_
        map[key] = value

      if error != null: handle-error_ error checkpoint

    offset_++
    return map

  decode-list_:
    expect_ '['

    list := []

    while true:
      checkpoint := offset_

      error := catch:
        offset_ = skip-whitespaces_ bytes_ offset_

        if bytes_[offset_] == ']': break

        if list.size > 0: expect_ ','

        value := decode_
        list.add value

      if error != null: handle-error_ error checkpoint

    offset_++
    return list

  // Overridden by StreamingDecoder
  handle-error_ error checkpoint/int -> none:
    throw error

  // An int used as a 32-entry bitmap that distinguishes between
  // characters that can continue a number and characters that
  // can terminate a number.  See explanation in the primitive code.
  static NUMBER-TABLE ::= 0x3ff6820
  // A bitmap that identifies which characters indicate a floating
  // point number.  Those characters are '.', 'e', and 'E'.
  static FLOAT-TABLE  ::=    0x4020

  static simple-size-of-number bytes offset -> int:
    #primitive.core.size-of-json-number:
      is-float := 0
      o := offset + 1
      for ; o < bytes.size; o++:
        c := bytes[o]
        // Unicode characters can't be part of a number.  Carriage return is
        // misidentified as a continuation of a number by the bitmap and must
        // be handled specially.
        if c == null or c == '\r': break
        if (NUMBER-TABLE >> (c & 0x1f)) & 1 == 0: break
        is-float |= (FLOAT-TABLE >> (c & 0x1f)) & 1
      return is-float == 1 ? -o : o

  decode-number_:
    o/int := simple-size-of-number bytes_ offset_
    start := offset_
    offset_ = o.abs
    // If the number ends at the end of the buffer we need to read more to
    // see if it continues in the next byte array.  (The throw triggers
    // another read in streaming mode.)
    if offset_ == bytes_.size and buffered-reader_: throw "UNEXPECTED_END_OF_INPUT"

    data := bytes_ is StringView_ ? bytes_.str_ : bytes_
    if o < 0: return float.parse_ data start -o --on-error=: throw it
    return int.parse_ data start o --radix=10 --on-error=: throw it

  decode-true_:
    "true".do: expect_ it
    return true

  decode-false_:
    "false".do: expect_ it
    return false

  decode-null_:
    "null".do: expect_ it
    return null

  expect_ byte:
    if bytes_[offset_++] != byte: throw "INVALID_JSON_CHARACTER"

  static skip-whitespaces_ bytes offset -> int:
    #primitive.core.json-skip-whitespace:
      while offset < bytes.size:
        c := bytes[offset]
        if c != ' ' and c != '\n' and c != '\t' and c != '\r':
          return offset
        offset++
      return offset


class StreamingDecoder extends Decoder:
  /// $reader can be either an $io.Reader, $Reader or a $BufferedReader.
  /// Support for $Reader and $BufferedReader will be removed in a future.
  decode-stream reader -> any:
    if reader is not io.Reader:
      buffered-reader_ = io.Reader.adapt reader
    else:
      buffered-reader_ = reader as io.Reader
    seen-strings_ = {}
    // Skip whitespace to get to the first data, which might be
    // a top-level number.
    while true:
      offset_ = 0
      bytes_ = reader.read
      if not bytes_: throw "EMPTY_READER"
      offset_ = Decoder.skip-whitespaces_ bytes_ offset_
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
      while get-more_:
        // Slurp up whole stream.
      buffered-reader_ = null  // Use non-incremental parsing.

    while true:
      error := catch:
        result := decode_
        if offset_ != bytes_.size:
          buffered-reader_.unget bytes_[offset_..]
          if reader is BufferedReader and buffered-reader_.buffered-size != 0:
            // Copy over the buffered data to the reader that was passed in.
            (reader as BufferedReader).unget (buffered-reader_.peek-bytes buffered-reader_.buffered-size)
        bytes_ = null
        offset_ = 0
        return result
      if error is WrappedException_:
        throw error.inner
      offset_ = 0
      if not get-more_:
        throw error

  // Returns true if we still have input.
  get-more_ -> bool:
    if not buffered-reader_: return false
    old-bytes := bytes_
    next-bytes/ByteArray? := #[]
    while next-bytes.size == 0:
      error := catch:
        next-bytes = buffered-reader_.read
      if error:
        throw (WrappedException_ error)
      if not next-bytes: return false
    bytes_ = old-bytes + next-bytes
    return true

  handle-error_ error checkpoint/int -> none:
    if error is WrappedException_: throw error
    bytes_ = bytes_[checkpoint..]
    offset_ = 0
    if not get-more_:
      throw (WrappedException_ error)
    offset_ = Decoder.skip-whitespaces_ bytes_ offset_

class StringView_:
  str_ ::= ?

  constructor .str_:

  operator [] i:
    return str_.at --raw i

  operator [..] --from=0 --to=size:
    return StringView_ str_[from..to]

  to-string from to:
    return str_.copy from to

  size:
    return str_.size

class WrappedException_:
  inner ::= ?

  constructor .inner:
