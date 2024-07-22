// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import bitmap
import io
import io show LITTLE-ENDIAN

INITIAL-BUFFER-SIZE_ ::= 64

abstract class EncoderBase_:
  writer_/io.Writer

  constructor .writer_:

  encode obj/any [converter]:
    if obj is string: encode-string_ obj
    else if obj is num: encode-number_ obj
    else if identical obj true: encode-true_
    else if identical obj false: encode-false_
    else if identical obj null: encode-null_
    else if obj is Map: encode-map_ obj converter
    else if obj is List: encode-list_ obj converter
    else:
      result := converter.call obj this
      if result != null: encode result converter

  encode obj/any converter/Lambda:
    encode obj: converter.call obj this

  encode obj/any:
    encode obj: throw "INVALID_JSON_OBJECT"

  abstract encode-string_ str
  abstract encode-number_ number
  abstract encode-true_
  abstract encode-false_
  abstract encode-null_
  abstract encode-map_ map [converter]
  abstract encode-list_ list [converter]

  /**
  Outputs a list-like thing to the serialized stream.
  This can be used by converter blocks.
  The generator is called repeatedly with indices from 0 to size - 1.
  */
  abstract put-list size/int [generator] [converter]

  put-unicode-escape_ code-point/int:
    writer := writer_
    writer.write-byte 'u'
    writer.write-byte
      to-lower-case-hex (code-point >> 12) & 0xf
    writer.write-byte
      to-lower-case-hex (code-point >> 8) & 0xf
    writer.write-byte
      to-lower-case-hex (code-point >> 4) & 0xf
    writer.write-byte
      to-lower-case-hex code-point & 0xf

  to-string -> string:
    return (writer_ as io.Buffer).to-string

  to-byte-array -> ByteArray:
    return (writer_ as io.Buffer).bytes

  /**
  Outputs a string or ByteArray directly to the JSON stream.
  No quoting, no escaping.  This is mainly used for things
    that will be parsed as numbers or strings by the receiver.
  */
  put-unquoted data/io.Data -> none:
    writer_.write data

ESCAPED-CHAR-MAP_ ::= create-escaped-char-map_
ONE-CHAR-ESCAPES_ ::= {
    '\b': 'b',
    '\f': 'f',
    '\n': 'n',
    '\r': 'r',
    '\t': 't',
    '"':  '"',
    '\\': '\\'
}

/**
A non-zero for every UTF-8 code unit that needs escaping, and a '0' for
  every code unit that doesn't need escaping.  The number indicates how
  many extra bytes the escaped version has.
*/
create-escaped-char-map_ -> ByteArray:
  // Most control characters (0-31) are output in the form \u00.. which takes 6
  // characters (5 extra).
  result := ByteArray 0x100: it < ' ' ? 5 : 0
  ONE-CHAR-ESCAPES_.do: | code escape | result[code] = 1
  return result

/**
Returns a string or a byte array that has been escaped for use in JSON/YAML.
This means that control characters, double quotes and backslashes have
  been replaced by backslash sequences.
*/
escape-string str/string -> any:
  if str == "" or str.size == 1 and ESCAPED-CHAR-MAP_[str[0]] == 0: return str
  counter := ByteArray 2
  bitmap.blit str counter str.size
      --destination-pixel-stride=0
      --lookup-table=ESCAPED-CHAR-MAP_
      --operation=bitmap.ADD-16-LE
  extra-chars := LITTLE-ENDIAN.uint16 counter 0
  if extra-chars == 0: return str  // Nothing to escape.
  if extra-chars == 0xffff:
    // Overflow of the saturating counter :-(.  We must count manually.
    extra-chars = 0
    str.size.repeat: extra-chars += ESCAPED-CHAR-MAP_[str.at --raw it]
  result := ByteArray str.size + extra-chars
  output-posn := 0
  not-yet-copied := 0
  str.size.repeat: | i |
    byte := str.at --raw i
    if ESCAPED-CHAR-MAP_[byte] != 0:
      result.replace output-posn str not-yet-copied i
      output-posn += i - not-yet-copied
      not-yet-copied = i + 1
      result[output-posn++] = '\\'
      if ONE-CHAR-ESCAPES_.contains byte:
        result[output-posn++] = ONE-CHAR-ESCAPES_[byte]
      else:
        result[output-posn    ] = 'u'
        result[output-posn + 1] = '0'
        result[output-posn + 2] = '0'
        result[output-posn + 3] = to-lower-case-hex byte >> 4
        result[output-posn + 4] = to-lower-case-hex byte & 0xf
        output-posn += 5
  result.replace output-posn str not-yet-copied str.size
  return result
