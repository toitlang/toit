// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import binary show LITTLE-ENDIAN
import bitmap
import reader show Reader BufferedReader
import .encoder
import .decoder

INITIAL-BUFFER-SIZE_ ::= 64
MAX-BUFFER-GROWTH_ ::= 1024

/**
Encodes the $obj as a YANL ByteArray.
The $obj must be a supported type, which means either a type supported
  by the $converter block or an instance of int, bool, float, string, List
  or Map.
Maps must have only string keys.  The elements of lists and the values of
  maps can be any of the above supported types.
The $converter block is passed an object to be serialized and an instance
  of the $Encoder class.  If it returns a non-null value, that value will
  be serialized instead of the object that was passed in.  Alternatively,
  the $converter block can call the $Encoder.encode, $Encoder.put-list,
  or Encoder.put_unquoted methods on the encoder.
Utf-8 encoding is used for strings.
*/
encode obj [converter] -> ByteArray:
  e := YamlEncoder_
  e.encode obj converter
  return e.to-byte-array

encode obj converter/Lambda -> ByteArray:
  return encode obj: | obj encoder | converter.call obj encoder

/**
Encodes the $obj as a YAML ByteArray.
The $obj must be null or an instance of int, bool, float, string, List, or Map.
Maps must have only string keys.  The elements of lists and the values of
  maps can be any of the above supported types.
Utf-8 encoding is used for strings.
*/
encode obj -> ByteArray:
  return encode obj: throw "INVALID_YAML_OBJECT"

/**
Decodes the $bytes, which is a ByteArray in YAML format.
The result is null or an instance of int, bool, float, string, List, or Map.
  The list elements and map values will also be one of these types.
Only a subset of YAML is supported.
*/
decode bytes/ByteArray -> any:
  d := Decoder
  return d.decode bytes

/**
Encodes the $obj as a YAML string.
The $obj must be a supported type, which means either a type supported
  by the $converter block or an instance of int, bool, float, string, List
  or Map.
Maps must have only string keys.  The elements of lists and the values of
  maps can be any of the above supported types.
The $converter block is passed an object to be serialized and an instance
  of the $Encoder class.  If it returns a non-null value, that value will
  be serialized instead of the object that was passed in.  Alternatively,
  the $converter block can call the $Encoder.encode, $Encoder.put-list,
  or Encoder.put_unquoted methods on the encoder.
Utf-8 encoding is used for strings.
Only a subset of YAML is supported.
*/
stringify obj/any [converter] -> string:
  e := YamlEncoder_
  e.encode obj converter
  return e.to-string

stringify obj converter/Lambda -> string:
  return stringify obj: | obj encoder | converter.call obj encoder

/**
Encodes the $obj as a YAML string.
The $obj must be null or an instance of int, bool, float, string, List, or Map.
  Maps must have only string keys.  The elements of lists and the values of
  maps can be any of the above supported types.
*/
stringify obj/any -> string:
  return stringify obj: throw "INVALID_YAML_OBJECT"

/**
Decodes the $str, which is a string in YAML format.
The result is null or an instance of of int, bool, float, string, List, or Map.
  The list elements and map values will also be one of these types.
Only a subset of YAML is supported.
*/
parse str/string:
  d := Decoder
  // size --runes is a highly optimized way to find the number of code points in a string.
  if str.size == (str.size --runes):
    return d.decode str
  // String contains non-ASCII UTF-8 characters, so we have to use a shim that
  // makes the string more like a ByteArray.
  return d.decode (StringView_ str)


class Decoder:
  tokenizer/Tokenizer_? := null
  tokens/Deque := Deque
  last_indent_/int := 0

  buffered-reader_/BufferedReader? := null

  current-token_ -> Token:
    if tokens.is-empty: tokens.add tokenizer.next
    return tokens.first

  peek-token_ --look-ahead/int=1 -> Token:
    while tokens.size <= look-ahead: tokens.add tokenizer.next
    return tokens[look-ahead]

  consume-token_:
    tokens.remove-first

  next-token-is-whitespace_ -> bool:
    return peek-token_.type == TOKEN_WHITESPACE

  decode bytes -> any:
    tokenizer = Tokenizer_ bytes
    return decode_

  decode_:
    token := current-token_
    while token.type == TOKEN_WHITESPACE:
      consume-token_
      token = current-token_
    while token.type == TOKEN_SPECIAL_CHAR and token.val == '%':
      while current-token_.type != TOKEN_INDENT: consume-token_
      consume-token_

    if token.type == TOKEN_EOF: throw "INVALID_YAML"
    if token.type == TOKEN_INDENT: throw "INVALID_YAML"
    if token.type == TOKEN_QUOTED_STRING:
      consume-token_
      return decode-scalar-or-indented-map_ token.val --string
    if token.type == TOKEN_NORMAL_CHAR_SEQUENCE:
      return decode-scalar-or-indented-map_ (decode-plain_ --flow=false)
    if token.type == TOKEN_SPECIAL_CHAR:
      if token.val == "-" and next-token-is-whitespace_:
        return decode-indented-list_
      if token.val == "[":
        return decode-flow-list_
      if token.val == "{":
        return decode-flow-map_
      if token.val == '%':
        while current-token_.type != TOKEN_INDENT: consume-token_

    throw "INVALID_OR_UNSUPPORTED_YAML"

  decode-plain_ --flow:
    return ""

  decode-scalar-or-indented-map_ key-or-scalar/string --string/bool=false:
    return key-or-scalar
  decode-indented-list_:
    return []
  decode-flow-list_: return []
  decode-flow-map_: return {:}

class Token:
  type/int
  val/any

  constructor .type .val:

TOKEN_WHITESPACE ::= 0
TOKEN_SPECIAL_CHAR ::= 1
TOKEN_NORMAL_CHAR_SEQUENCE ::= 2
TOKEN_INDENT ::= 3
TOKEN_EOF ::= 4
TOKEN_QUOTED_STRING ::= 5

SPECIAL_CHARS_ ::= {
  '-',
  '?',
  ':',
  ',',
  '[',
  ']',
  '{',
  '}',
  '&',
  '*',
  '!',
  '|',
  '>',
  '%'
  }

class Tokenizer_ extends DecoderBase_:
  eof/Token := Token TOKEN_EOF null

  constructor bytes:
    bytes_ = bytes

  next-token -> Token:
    c := next
    if not c: return eof

    if SPECIAL_CHARS_.contains c: return Token TOKEN_SPECIAL_CHAR c

    if c == ' ' or c == '\t':
      start := offset_
      while peek == ' ' or peek == '\t':
        next
      return Token TOKEN_WHITESPACE bytes_[start..offset_]

    if c == '#':
      while peek != '\n':
        next
      return next-token

    if c == '\n':
      line-start := offset_
      while peek == ' ':
        next
      return Token TOKEN_INDENT offset_ - line-start

    if c == '"' or c == '\'':
      return decode-quoted-string_ YAML_ESCAPEES_ "UNTERMINATED_YAML_STRING" --quote-char=c --allow-x-escape

    start-scalar := offset_

    while true:
      peek := peek
      if not peek: break
      if peek == '\n' or
           peek == ' ' or
           peek == '\t' or
           SPECIAL_CHARS_.contains peek:
         break
      next

    return Token TOKEN_NORMAL_CHAR_SEQUENCE bytes_[start-scalar..offset_]

  next:
    if offset_ >= bytes_.size:
      return null
    return bytes_[offset_++]

  peek:
    if offset_ >= bytes_.size:
      return null
    return bytes_[offset_]
