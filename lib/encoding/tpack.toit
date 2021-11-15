// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

// Encoding and decoding of simple objects into the Toit-specific 'tpack' binary format.
// Format is described here https://github.com/toitware/console/blob/master/pkg/tpack/README.md

import .maskint as maskint
import binary show LITTLE_ENDIAN
import .protobuf as protobuf
import bytes

ERR_INVALID_MESSAGE ::= "INVALID_MESSAGE"
ERR_UNSUPPORTED_TYPE ::= "UNSUPPORTED_TYPE"
ERR_INVALID_TYPE ::= "INVALID_TYPE"
ERR_STRUCT_NOT_INITIALIZED ::= "STRUCT_NOT_INITIALIZED"
ERR_UNSUPPORTED_FIELD_TYPE ::= "UNSUPPORTED_FIELD_TYPE"

TPACK_VERSION_INVALID := 0
TPACK_VERSION_1 := 1

TPACK_EMBEDDED_FIELD_TYPE_MASK_ := 0b00000111

TPACK_FIELD_TYPE_MASKINT_ ::= 0
TPACK_FIELD_TYPE_64_BIT_  ::= 1
TPACK_FIELD_TYPE_32_BIT_  ::= 2
TPACK_FIELD_TYPE_STRUCT_  ::= 3
TPACK_FIELD_TYPE_ARRAY_   ::= 4
TPACK_FIELD_TYPE_MAP_     ::= 5
TPACK_FIELD_TYPE_SIZED_   ::= 6
TPACK_FIELD_TYPE_INVALID_ ::= 255

encode msg/protobuf.Message -> ByteArray:
  buffer := bytes.Buffer
  writer := Writer buffer
  msg.serialize writer
  return buffer.bytes

protobuf_to_tpack_type_ protobuf_type/int -> int:
  if protobuf_type == protobuf.PROTOBUF_TYPE_DOUBLE:
    return TPACK_FIELD_TYPE_64_BIT_
  else if protobuf_type == protobuf.PROTOBUF_TYPE_FLOAT:
    return TPACK_FIELD_TYPE_32_BIT_
  else if protobuf.PROTOBUF_TYPE_BOOL <= protobuf_type and
          protobuf_type <= protobuf.PROTOBUF_TYPE_ENUM:
    return TPACK_FIELD_TYPE_MASKINT_
  else if protobuf_type == protobuf.PROTOBUF_TYPE_STRING or
          protobuf_type == protobuf.PROTOBUF_TYPE_BYTES:
    return TPACK_FIELD_TYPE_SIZED_
  else if protobuf_type == protobuf.PROTOBUF_TYPE_MESSAGE:
    return TPACK_FIELD_TYPE_STRUCT_
  else:
    throw ERR_UNSUPPORTED_TYPE

class Message implements protobuf.Reader:
  bytes_/ByteArray ::= ?

  read_offset_/int := 1

  curr_field_type_/int? := null
  struct_count_/int? := null

  constructor.in .bytes_:
    if bytes_[0] != TPACK_VERSION_1:
      throw ERR_INVALID_MESSAGE

  reset -> none:
    read_offset_ = 1

  read_maskint -> int:
    i := maskint.decode bytes_ read_offset_
    skip_maskint i
    return i

  peek_maskint -> int:
    i := maskint.decode bytes_ read_offset_
    return i

  skip_maskint:
    read_offset_ += maskint.byte_size --offset=read_offset_ bytes_

  skip_maskint i/int:
    read_offset_ += maskint.size i

  read_primitive protobuf_type/int -> any:
    field_type := curr_field_type_
    if field_type == null:
      field_type = read_maskint

    if protobuf_type == protobuf.PROTOBUF_TYPE_DOUBLE:
      result := LITTLE_ENDIAN.float64 bytes_ read_offset_
      read_offset_ += 8
      return result
    else if protobuf_type == protobuf.PROTOBUF_TYPE_FLOAT:
      result := LITTLE_ENDIAN.float32 bytes_ read_offset_
      read_offset_ += 4
      return result
    else if protobuf.PROTOBUF_TYPE_INT64 <= protobuf_type and
            protobuf_type <= protobuf.PROTOBUF_TYPE_SFIXED32:
      result := read_maskint
      return (result >> 1) ^ -(result & 1)
    else if protobuf.PROTOBUF_TYPE_UINT64 <= protobuf_type and
            protobuf_type <= protobuf.PROTOBUF_TYPE_ENUM:
      return read_maskint
    else if protobuf_type == protobuf.PROTOBUF_TYPE_BOOL:
      return bytes_[read_offset_++] != 0
    else if protobuf_type == protobuf.PROTOBUF_TYPE_STRING:
      size := read_maskint
      result := bytes_.to_string read_offset_ read_offset_+size
      read_offset_ += size
      return result
    else if protobuf_type == protobuf.PROTOBUF_TYPE_BYTES:
      size := read_maskint
      result := bytes_.copy read_offset_ read_offset_+size
      read_offset_ += size
      return result

    throw ERR_INVALID_TYPE

  read_array _/int array/List [construct_value] -> List:
    count := read_maskint
    value_type := count & TPACK_EMBEDDED_FIELD_TYPE_MASK_
    count = count >> 3
    return List count (:
      prev_field_type := curr_field_type_
      curr_field_type_ = value_type
      result := construct_value.call
      curr_field_type_ = prev_field_type
      result
    )

  skip_array:
    field_type := curr_field_type_
    if field_type == null:
      field_type = read_maskint

    if field_type != TPACK_FIELD_TYPE_MAP_:
      throw ERR_UNSUPPORTED_FIELD_TYPE

    count := read_maskint
    value_type := count & TPACK_EMBEDDED_FIELD_TYPE_MASK_
    count = count >> 3
    count.repeat:
      skip_element value_type

  read_map map/Map [construct_key] [construct_value] -> Map:
    field_type := curr_field_type_
    if field_type == null:
      field_type = read_maskint

    if field_type != TPACK_FIELD_TYPE_MAP_:
      throw ERR_UNSUPPORTED_FIELD_TYPE

    count := read_maskint
    value_type := count & TPACK_EMBEDDED_FIELD_TYPE_MASK_
    count = count >> 3
    key_type := count & TPACK_EMBEDDED_FIELD_TYPE_MASK_
    count = count >> 3

    return Map count
      (:
        prev_field_type := curr_field_type_
        curr_field_type_ = key_type
        result := construct_key.call
        curr_field_type_ = prev_field_type
        result
      )
      (:
        prev_field_type := curr_field_type_
        curr_field_type_ = value_type
        result := construct_value.call
        curr_field_type_ = prev_field_type
        result
      )

  skip_map:
    count := read_maskint
    value_type := count & TPACK_EMBEDDED_FIELD_TYPE_MASK_
    count = count >> 3
    key_type := count & TPACK_EMBEDDED_FIELD_TYPE_MASK_
    count = count >> 3

    count.repeat:
      skip_element key_type
      skip_element value_type

  read_message [construct_message]:
    field_type := curr_field_type_
    if field_type == null:
      field_type = read_maskint

    if field_type != TPACK_FIELD_TYPE_STRUCT_:
      throw ERR_UNSUPPORTED_FIELD_TYPE

    count := read_maskint

    // store current state.
    prev_struct_count := struct_count_
    struct_count_ = count

    construct_message.call

    struct_count_.repeat:
      skip_field

    // restore old state.
    struct_count_ = prev_struct_count

  skip_message:
    count := read_maskint
    count.repeat:
      skip_field

  skip_element field_type/int:
    if field_type == TPACK_FIELD_TYPE_MASKINT_:
      skip_maskint
    else if field_type == TPACK_FIELD_TYPE_64_BIT_:
      read_offset_ += 8
    else if field_type == TPACK_FIELD_TYPE_32_BIT_:
      read_offset_ += 4
    else if field_type == TPACK_FIELD_TYPE_STRUCT_:
      skip_message
    else if field_type == TPACK_FIELD_TYPE_ARRAY_:
      skip_array
    else if field_type == TPACK_FIELD_TYPE_MAP_:
      skip_map
    else if field_type == TPACK_FIELD_TYPE_SIZED_:
      size := read_maskint
      read_offset_ += size
    else:
      throw ERR_UNSUPPORTED_FIELD_TYPE

  read_field field_pos/int [construct_field]:
    if struct_count_ == null:
      throw ERR_STRUCT_NOT_INITIALIZED

    while struct_count_ > 0:
      field_mask := peek_maskint
      field_type := field_mask & TPACK_EMBEDDED_FIELD_TYPE_MASK_
      pos := field_mask >> 3

      if pos > field_pos:
        return

      skip_maskint field_mask

      struct_count_--
      if pos < field_pos:
        skip_element field_type
        continue

      prev_field_type := curr_field_type_
      curr_field_type_ = field_type
      construct_field.call
      curr_field_type_ = prev_field_type
      return

  skip_field:
    if struct_count_ == null:
      throw ERR_STRUCT_NOT_INITIALIZED
    if struct_count_ <= 0:
      return

    pos := read_maskint
    field_type := pos & TPACK_EMBEDDED_FIELD_TYPE_MASK_
    skip_element field_type
    struct_count_--


class Writer implements protobuf.Writer:
  // We reuse the buffer across writers. This works because serialization
  // cannot yield.
  static MASKINT_BUFFER_/ByteArray := ByteArray 9

  // TODO: change the type of out to some Writer interface.
  out_/bytes.Buffer

  message_header_written_/bool := false
  collection_count_/int := 0

  constructor .out_:

  with_field_type_header_ -> bool:
    return collection_count_ == 0

  reset:
    message_header_written_ = false
    collection_count_ = 0
    out_.clear

  buffer_ -> ByteArray:
    return out_.buffer

  send_message_header_:
    if not message_header_written_:
      out_.put_byte TPACK_VERSION_1
      message_header_written_ = true

  write_field_type_ type/int as_field/int? -> int:
    if as_field != null:
      return write_maskint_
        (as_field << 3) | type
    if with_field_type_header_:
      return write_maskint_ type
    return 0

  offset_reserved_ size:
    offset := out_.size
    out_.grow size
    return offset

  write_primitive protobuf_type/int value/any --oneof/bool=false --as_field/int?=null -> none:
    send_message_header_

    can_skip := not oneof and as_field != null

    if protobuf_type == protobuf.PROTOBUF_TYPE_DOUBLE:
      if can_skip and value == 0.0:
        return
      write_field_type_ TPACK_FIELD_TYPE_64_BIT_ as_field
      offset := offset_reserved_ 8
      LITTLE_ENDIAN.put_float64 buffer_ offset value
    else if protobuf_type == protobuf.PROTOBUF_TYPE_FLOAT:
      if can_skip and value == 0.0:
        return
      write_field_type_ TPACK_FIELD_TYPE_32_BIT_ as_field
      offset := offset_reserved_ 4
      LITTLE_ENDIAN.put_float32 buffer_ offset value
    else if protobuf.PROTOBUF_TYPE_INT64 <= protobuf_type <= protobuf.PROTOBUF_TYPE_SFIXED32:
      if can_skip and value == 0:
        return
      write_field_type_ TPACK_FIELD_TYPE_MASKINT_ as_field
      write_maskint_ (value >> 63) ^ (value << 1)
    else if protobuf.PROTOBUF_TYPE_UINT64 <= protobuf_type <= protobuf.PROTOBUF_TYPE_ENUM:
      if as_field != null and value == 0:
        return
      write_field_type_ TPACK_FIELD_TYPE_MASKINT_ as_field
      write_maskint_ value
    else if protobuf_type == protobuf.PROTOBUF_TYPE_BOOL:
      if can_skip and not value:
        return
      write_field_type_ TPACK_FIELD_TYPE_MASKINT_ as_field
      out_.put_byte (value ? 1 : 0)
    else if protobuf_type == protobuf.PROTOBUF_TYPE_STRING:
      if can_skip and value == "":
        return
      write_field_type_ TPACK_FIELD_TYPE_SIZED_ as_field
      write_maskint_ value.size
      out_.write value
    else if protobuf_type == protobuf.PROTOBUF_TYPE_BYTES:
      if can_skip and value.is_empty:
        return
      write_field_type_ TPACK_FIELD_TYPE_SIZED_ as_field
      write_maskint_ value.size
      out_.write value
    else:
      throw ERR_UNSUPPORTED_TYPE

  write_array protobuf_value_type/int array/List --oneof/bool=false --as_field/int?=null [serialize_value] -> none:
    send_message_header_
    if not oneof and as_field != null and array.is_empty:
      return
    write_field_type_ TPACK_FIELD_TYPE_ARRAY_ as_field

    collection_count_++

    // TODO(anders): Don't use artificial scopes when the compiler has optimizations around it.
    if true:
      value_type := protobuf_to_tpack_type_ protobuf_value_type
      count := array.size
      write_maskint_ (count << 3) | value_type

    array.do serialize_value

    collection_count_--

  write_map protobuf_key_type/int protobuf_value_type/int map/Map --oneof/bool=false --as_field/int?=null [serialize_key] [serialize_value] -> none:
    send_message_header_
    if not oneof and as_field != null and map.is_empty:
      return
    write_field_type_ TPACK_FIELD_TYPE_MAP_ as_field

    collection_count_++

    // TODO(anders): Don't use artificial scopes when the compiler has optimizations around it.
    if true:
      key_type := protobuf_to_tpack_type_ protobuf_key_type
      value_type := protobuf_to_tpack_type_ protobuf_value_type
      count := map.size
      write_maskint_ ((count << 3 | key_type) << 3) | value_type

    map.do: | k v |
      serialize_key.call k
      serialize_value.call v

    collection_count_--

  write_message_header msg/protobuf.Message --oneof/bool=false --as_field/int?=null -> none:
    send_message_header_
    num_fields_set := msg.num_fields_set
    if not oneof and as_field != null and num_fields_set == 0:
      return
    write_field_type_ TPACK_FIELD_TYPE_STRUCT_ as_field
    write_maskint_ num_fields_set

  write_maskint_ i/int -> int:
    size := maskint.encode MASKINT_BUFFER_ 0 i
    return out_.write MASKINT_BUFFER_ 0 size
