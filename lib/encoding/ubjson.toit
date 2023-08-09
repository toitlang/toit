// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import binary
import bytes

INVALID-INPUT-ERROR ::= "INVALID_UBJSON_INPUT"
INVALID-OBJECT-ERROR ::= "INVALID_UBJSON_OBJECT"
INVALID-CHARACTER-ERROR ::= "INVALID_UBJSON_CHARACTER"

encode obj/any -> ByteArray:
  e := Encoder
  e.encode obj
  return e.to-byte-array

decode bytes/ByteArray -> any:
  d := Decoder bytes
  val := d.decode
  if not d.is-done: throw INVALID-INPUT-ERROR
  return val

class Encoder:
  buffer_/bytes.BufferConsumer? := null

  encode obj -> none:
    if buffer_ == null:
      // The first time we are called, calculate the size and make the buffer
      // the exact right size.  If we are only called once this enables the
      // buffer to be the exact right size.  However, if we are called again we
      // just continue building without knowing the final size.
      size-counter := bytes.BufferSizeCounter
      buffer_ = size-counter
      encode_ obj  // Calculate size.
      buffer := bytes.Buffer.with-initial-size size-counter.size
      buffer_ = buffer
    encode_ obj

  encode_ obj:
    if obj is string: encode-string_ obj
    else if obj is int: encode-int_ obj
    else if obj is float: encode-float_ obj
    else if identical obj true: encode-true_
    else if identical obj false: encode-false_
    else if identical obj null: encode-null_
    else if obj is Map: encode-map_ obj
    else if obj is ByteArray: encode-bytes_ obj
    else if obj is List or obj is Array_: encode-list_ obj
    else if obj is bytes.Producer: encode-byte-producer_ obj
    else: throw INVALID-OBJECT-ERROR

  /**
  Returns the objects serialized up to this point as a byte array.
  */
  to-byte-array:
    return (buffer_ as bytes.Buffer).bytes

  encode-map_ map:
    buffer_.write-byte '{'
    buffer_.write-byte '#'
    encode-int_ map.size
    map.do: | key value |
      encode-string-inner_ key
      encode_ value

  encode-bytes_ bytes:
    buffer_.write-byte '['
    buffer_.write-byte '$'
    buffer_.write-byte 'U'
    buffer_.write-byte '#'
    encode-int_ bytes.size
    buffer_.write bytes

  encode-byte-producer_ bytes:
    buffer_.write-byte '['
    buffer_.write-byte '$'
    buffer_.write-byte 'U'
    buffer_.write-byte '#'
    encode-int_ bytes.size
    buffer_.write-producer bytes

  encode-list_ list:
    buffer_.write-byte '['
    buffer_.write-byte '#'
    encode-int_ list.size
    for i := 0; i < list.size; i++:
      encode_ list[i]

  encode-string_ str:
    buffer_.write-byte 'S'
    encode-string-inner_ str

  encode-string-inner_ str:
    encode-int_ str.size
    buffer_.write str

  encode-float_ f:
    buffer_.write-byte 'D'
    offset := offset-reserved_ 8
    buffer_.put-int64-big-endian offset f.bits

  encode-int_ i:
    if 0 <= i <= binary.UINT8-MAX:
      buffer_.write-byte 'U'
      buffer_.write-byte i
    else if binary.INT8-MIN <= i <= binary.INT8-MAX:
      buffer_.write-byte 'i'
      buffer_.write-byte i
    else if binary.INT16-MIN <= i <= binary.INT16-MAX:
      buffer_.write-byte 'I'
      offset := offset-reserved_ 2
      buffer_.put-int16-big-endian offset i
    else if binary.INT32-MIN <= i <= binary.INT32-MAX:
      buffer_.write-byte 'l'
      offset := offset-reserved_ 4
      buffer_.put-int32-big-endian offset i
    else:
      buffer_.write-byte 'L'
      offset := offset-reserved_ 8
      buffer_.put-int64-big-endian offset i

  encode-true_:
    buffer_.write-byte 'T'

  encode-false_:
    buffer_.write-byte 'F'

  encode-null_:
    buffer_.write-byte 'Z'

  offset-reserved_ size:
    offset := buffer_.size
    buffer_.grow size
    return offset

class Decoder:
  bytes_ := ?
  offset_ := 0

  constructor .bytes_:

  is-done:
    // Skip trailing nops.
    while offset_ < bytes_.size and bytes_[offset_] == 'N': offset_++
    return offset_ == bytes_.size

  decode:
    return decode_ decode-type_

  decode_ type:
    if type == 'S': return decode-string_
    if type == '{': return decode-map_
    if type == '[': return decode-list_
    if type == 'T': return true
    if type == 'F': return false
    if type == 'Z': return null
    return decode-number_ type

  decode-string_:
    size := decode-int_ decode-type_
    str := bytes_.to-string offset_ offset_ + size
    offset_ += size
    return str

  decode-number_ type:
    if type == 'D': return decode-float_
    return decode-int_ type

  decode-float_:
    offset_ += 8
    return float.from-bits (binary.BIG-ENDIAN.int64 bytes_ offset_ - 8)

  decode-int_ type:
    if type == 'i': return binary.BIG-ENDIAN.int8 bytes_ offset_++
    else if type == 'U': return bytes_[offset_++]
    else if type == 'I':
      offset_ += 2
      return binary.BIG-ENDIAN.int16 bytes_ offset_ - 2
    else if type == 'l':
      offset_ += 4
      return binary.BIG-ENDIAN.int32 bytes_ offset_ - 4
    else if type == 'L':
      offset_ += 8
      return binary.BIG-ENDIAN.int64 bytes_ offset_ - 8
    else:
      throw INVALID-CHARACTER-ERROR

  decode-map_:
    map := {:}

    type := 0
    if bytes_[offset_] == '$':
      offset_++
      type = decode-type_

    size := -1
    if bytes_[offset_] == '#':
      offset_++
      size = decode-int_ decode-type_

    i := 0
    while true:
      if size >= 0:
        if i == size: break
      else if bytes_[offset_] == '}':
        offset_++
        break

      key := decode-string_
      t := type > 0 ? type : decode-type_
      map[key] = decode_ t

      i++

    return map

  decode-list_:
    list := []

    type := 0
    if bytes_[offset_] == '$':
      offset_++
      type = decode-type_

    size := -1
    if bytes_[offset_] == '#':
      offset_++
      size = decode-int_ decode-type_

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

      t := type > 0 ? type : decode-type_
      list.add (decode_ t)

      i++

    return list

  decode-type_:
    return bytes_[offset_++]
