// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import binary
import bytes

INVALID_INPUT_ERROR ::= "INVALID_UBJSON_INPUT"
INVALID_OBJECT_ERROR ::= "INVALID_UBJSON_OBJECT"
INVALID_CHARACTER_ERROR ::= "INVALID_UBJSON_CHARACTER"

encode obj/any -> ByteArray:
  e := Encoder
  e.encode obj
  return e.to_byte_array

decode bytes/ByteArray -> any:
  d := Decoder bytes
  val := d.decode
  if not d.is_done: throw INVALID_INPUT_ERROR
  return val

class Encoder:
  buffer_/bytes.BufferConsumer? := null

  encode obj -> none:
    if buffer_ == null:
      // The first time we are called, calculate the size and make the buffer
      // the exact right size.  If we are only called once this enables the
      // buffer to be the exact right size.  However, if we are called again we
      // just continue building without knowing the final size.
      size_counter := bytes.BufferSizeCounter
      buffer_ = size_counter
      encode_ obj  // Calculate size.
      buffer := bytes.Buffer.with_initial_size size_counter.size
      buffer_ = buffer
    encode_ obj

  encode_ obj:
    if obj is string: encode_string_ obj
    else if obj is int: encode_int_ obj
    else if obj is float: encode_float_ obj
    else if identical obj true: encode_true_
    else if identical obj false: encode_false_
    else if identical obj null: encode_null_
    else if obj is Map: encode_map_ obj
    else if obj is ByteArray: encode_bytes_ obj
    else if obj is List or obj is Array_: encode_list_ obj
    else if obj is bytes.Producer: encode_byte_producer_ obj
    else: throw INVALID_OBJECT_ERROR

  /**
  Returns the objects serialized up to this point as a byte array.
  */
  to_byte_array:
    return (buffer_ as bytes.Buffer).bytes

  encode_map_ map:
    buffer_.put_byte '{'
    buffer_.put_byte '#'
    encode_int_ map.size
    map.do: | key value |
      encode_string_inner_ key
      encode_ value

  encode_bytes_ bytes:
    buffer_.put_byte '['
    buffer_.put_byte '$'
    buffer_.put_byte 'U'
    buffer_.put_byte '#'
    encode_int_ bytes.size
    buffer_.write bytes

  encode_byte_producer_ bytes:
    buffer_.put_byte '['
    buffer_.put_byte '$'
    buffer_.put_byte 'U'
    buffer_.put_byte '#'
    encode_int_ bytes.size
    buffer_.put_producer bytes

  encode_list_ list:
    buffer_.put_byte '['
    buffer_.put_byte '#'
    encode_int_ list.size
    for i := 0; i < list.size; i++:
      encode_ list[i]

  encode_string_ str:
    buffer_.put_byte 'S'
    encode_string_inner_ str

  encode_string_inner_ str:
    encode_int_ str.size
    buffer_.write str

  encode_float_ f:
    buffer_.put_byte 'D'
    offset := offset_reserved_ 8
    buffer_.put_int64_big_endian offset f.bits

  encode_int_ i:
    if 0 <= i <= binary.UINT8_MAX:
      buffer_.put_byte 'U'
      buffer_.put_byte i
    else if binary.INT8_MIN <= i <= binary.INT8_MAX:
      buffer_.put_byte 'i'
      buffer_.put_byte i
    else if binary.INT16_MIN <= i <= binary.INT16_MAX:
      buffer_.put_byte 'I'
      offset := offset_reserved_ 2
      buffer_.put_int16_big_endian offset i
    else if binary.INT32_MIN <= i <= binary.INT32_MAX:
      buffer_.put_byte 'l'
      offset := offset_reserved_ 4
      buffer_.put_int32_big_endian offset i
    else:
      buffer_.put_byte 'L'
      offset := offset_reserved_ 8
      buffer_.put_int64_big_endian offset i

  encode_true_:
    buffer_.put_byte 'T'

  encode_false_:
    buffer_.put_byte 'F'

  encode_null_:
    buffer_.put_byte 'Z'

  offset_reserved_ size:
    offset := buffer_.size
    buffer_.grow size
    return offset

class Decoder:
  bytes_ := ?
  offset_ := 0

  constructor .bytes_:

  is_done:
    // Skip trailing nops.
    while offset_ < bytes_.size and bytes_[offset_] == 'N': offset_++
    return offset_ == bytes_.size

  decode:
    return decode_ decode_type_

  decode_ type:
    if type == 'S': return decode_string_
    if type == '{': return decode_map_
    if type == '[': return decode_list_
    if type == 'T': return true
    if type == 'F': return false
    if type == 'Z': return null
    return decode_number_ type

  decode_string_:
    size := decode_int_ decode_type_
    str := bytes_.to_string offset_ offset_ + size
    offset_ += size
    return str

  decode_number_ type:
    if type == 'D': return decode_float_
    return decode_int_ type

  decode_float_:
    offset_ += 8
    return float.from_bits (binary.BIG_ENDIAN.int64 bytes_ offset_ - 8)

  decode_int_ type:
    if type == 'i': return binary.BIG_ENDIAN.int8 bytes_ offset_++
    else if type == 'U': return bytes_[offset_++]
    else if type == 'I':
      offset_ += 2
      return binary.BIG_ENDIAN.int16 bytes_ offset_ - 2
    else if type == 'l':
      offset_ += 4
      return binary.BIG_ENDIAN.int32 bytes_ offset_ - 4
    else if type == 'L':
      offset_ += 8
      return binary.BIG_ENDIAN.int64 bytes_ offset_ - 8
    else:
      throw INVALID_CHARACTER_ERROR

  decode_map_:
    map := {:}

    type := 0
    if bytes_[offset_] == '$':
      offset_++
      type = decode_type_

    size := -1
    if bytes_[offset_] == '#':
      offset_++
      size = decode_int_ decode_type_

    i := 0
    while true:
      if size >= 0:
        if i == size: break
      else if bytes_[offset_] == '}':
        offset_++
        break

      key := decode_string_
      t := type > 0 ? type : decode_type_
      map[key] = decode_ t

      i++

    return map

  decode_list_:
    list := []

    type := 0
    if bytes_[offset_] == '$':
      offset_++
      type = decode_type_

    size := -1
    if bytes_[offset_] == '#':
      offset_++
      size = decode_int_ decode_type_

    // Special case for byte arrays.
    if type == 'U' and size >= 0:
      offset_ += size
      return bytes_.copy offset_ - size offset_

    i := 0
    while true:
      if size >= 0:
        if i == size: break
      else if bytes_[offset_] == ']':
        offset_++
        break

      t := type > 0 ? type : decode_type_
      list.add (decode_ t)

      i++

    return list

  decode_type_:
    return bytes_[offset_++]
