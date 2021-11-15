// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import encoding.varint as varint
import binary show LITTLE_ENDIAN
import bytes

// 0 is reserved for errors.
PROTOBUF_TYPE_DOUBLE    ::= 1
PROTOBUF_TYPE_FLOAT     ::= 2
PROTOBUF_TYPE_BOOL      ::= 3

PROTOBUF_TYPE_INT64     ::= 4
PROTOBUF_TYPE_INT32     ::= 5
PROTOBUF_TYPE_SINT64    ::= 6
PROTOBUF_TYPE_SINT32    ::= 7
PROTOBUF_TYPE_SFIXED64  ::= 8
PROTOBUF_TYPE_SFIXED32  ::= 9

PROTOBUF_TYPE_UINT64    ::= 10
PROTOBUF_TYPE_UINT32    ::= 11
PROTOBUF_TYPE_FIXED64   ::= 12
PROTOBUF_TYPE_FIXED32   ::= 13
PROTOBUF_TYPE_ENUM      ::= 14

PROTOBUF_TYPE_STRING    ::= 15
PROTOBUF_TYPE_BYTES     ::= 16

PROTOBUF_TYPE_GROUP     ::= 17
PROTOBUF_TYPE_MESSAGE   ::= 18

interface Reader:
  read_primitive type/int -> any
  read_array value_type/int array/List [construct_value] -> List
  read_map map/Map [construct_key] [construct_value] -> Map
  read_message [construct_message] -> none
  read_field field_pos/int [construct_field] -> none
  reset -> none

  constructor in/ByteArray:
    return Reader_ in

interface Writer:
  write_primitive type/int value/any --as_field/int?=null --oneof/bool=false -> int
  write_array value_type/int array/List --as_field/int?=null --oneof/bool=false [serialize_value] -> int
  write_map key_type/int value_type/int map/Map --as_field/int?=null --oneof/bool=false [serialize_key] [serialize_value] -> none
  write_message_header msg/Message --as_field/int?=null --oneof/bool=false -> none
  reset -> none

  constructor out/bytes.Buffer:
    return Writer_ out

abstract class Message:
  // TODO: serialize should be abstract but default values
  // to flags are not allowed for abstract methods
  serialize writer/Writer --as_field/int?=null --oneof/bool=false -> none:
    return

  abstract num_fields_set -> int

  /// Returns the byte size used to encode the message in protobuf.
  abstract protobuf_size -> int

  is_empty -> bool:
    return num_fields_set == 0

/// Decodes a google.protobuf.Duration message into a $Duration.
deserialize_duration r/Reader -> Duration:
  result := Duration.ZERO
  seconds := 0
  nanos := 0
  r.read_message:
    r.read_field 1:
      seconds = r.read_primitive PROTOBUF_TYPE_INT64
    r.read_field 2:
      nanos = r.read_primitive PROTOBUF_TYPE_INT32
    result = Duration --s=seconds --ns=nanos
  return result

class FakeMessage_ extends Message:
  num_fields_set/int := ?
  protobuf_size/int := ?

  constructor .num_fields_set .protobuf_size:

  with num_fields_set .protobuf_size -> Message:
    this.num_fields_set = num_fields_set
    this.protobuf_size = protobuf_size
    return this

// We can reuse the fakeMessage_ since write_message_header will not do any recursing calls.
fakeMessage_ := FakeMessage_ 0 0

/// Encodes a $Duration into a google.protobuf.Duration message.
serialize_duration d/Duration w/Writer --as_field/int?=null --oneof/bool=false:
  seconds := d.in_s
  nanos := d.in_ns % Duration.NANOSECONDS_PER_SECOND
  num_fields_set :=
    (seconds == 0 ? 0 : 1) +
      (nanos == 0 ? 0 : 1)
  w.write_message_header (fakeMessage_.with num_fields_set (size_duration d)) --as_field=as_field --oneof=oneof
  if seconds != 0:
    w.write_primitive PROTOBUF_TYPE_INT64 seconds --as_field=1
  if nanos != 0:
    w.write_primitive PROTOBUF_TYPE_INT32 nanos --as_field=2

size_duration d/Duration --as_field/int?=null -> int:
  seconds := d.in_s
  nanos := d.in_ns % Duration.NANOSECONDS_PER_SECOND
  msg_size := (size_primitive PROTOBUF_TYPE_INT64 seconds --as_field=1)
    + (size_primitive PROTOBUF_TYPE_INT32 nanos --as_field=2)
  return size_embedded_message msg_size --as_field=as_field

/// Decodes a google.protobuf.Timestamp message into a $Time.
deserialize_timestamp r/Reader -> Time:
  result := TIME_ZERO_EPOCH
  seconds := 0
  nanos := 0
  r.read_message:
    r.read_field 1:
      seconds = r.read_primitive PROTOBUF_TYPE_INT64
    r.read_field 2:
      nanos = r.read_primitive PROTOBUF_TYPE_INT32
    result = Time.epoch --s=seconds --ns=nanos
  return result

/// Encodes a $Time into a google.protobuf.Timestamp message.
serialize_timestamp t/Time w/Writer --as_field/int?=null --oneof/bool=false -> none:
  seconds := t.s_since_epoch
  nanos := t.ns_part
  num_fields_set :=
    (seconds == 0 ? 0 : 1) +
      (nanos == 0 ? 0 : 1)
  w.write_message_header (fakeMessage_.with num_fields_set (size_timestamp t)) --as_field=as_field --oneof=oneof
  if seconds != 0:
    w.write_primitive PROTOBUF_TYPE_INT64 seconds --as_field=1
  if nanos != 0:
    w.write_primitive PROTOBUF_TYPE_INT32 nanos --as_field=2

size_timestamp t/Time --as_field/int?=null -> int:
  seconds := t.s_since_epoch
  nanos := t.ns_part
  msg_size := (size_primitive PROTOBUF_TYPE_INT64 seconds --as_field=1)
    + (size_primitive PROTOBUF_TYPE_INT32 nanos --as_field=2)
  return size_embedded_message msg_size --as_field=as_field

time_is_zero_epoch t/Time -> bool:
  return t.ns_part == 0 and t.s_since_epoch == 0

TIME_ZERO_EPOCH/Time ::= Time.epoch

ERR_UNSUPPORTED_TYPE ::= "UNSUPPORTED_TYPE"
ERR_INVALID_TYPE ::= "INVALID_TYPE"
ERR_UNSUPPORTED_WIRE_TYPE ::= "UNSUPPORTED_WIRE_TYPE"

PROTOBUF_WIRE_TYPE_VARINT         ::= 0
PROTOBUF_WIRE_TYPE_64BIT          ::= 1
PROTOBUF_WIRE_TYPE_LEN_DELIMITED  ::= 2
PROTOBUF_WIRE_TYPE_START_GROUP    ::= 3
PROTOBUF_WIRE_TYPE_END_GROUP      ::= 4
PROTOBUF_WIRE_TYPE_32BIT          ::= 5

class Reader_ implements Reader:
  bytes_/ByteArray ::= ?

  read_offset_/int := 0
  msg_end/int? := null
  current_wire_type/int? := null

  constructor .bytes_:

  reset -> none:
    read_offset_ = 0
    msg_end = null

  read_varint_ -> int:
    i := varint.decode bytes_ read_offset_
    skip_varint_ i
    return i

  peek_varint_ -> int:
    i := varint.decode bytes_ read_offset_
    return i

  skip_varint_ i/int:
    read_offset_ += varint.size i

  skip_varint_:
    read_offset_ += varint.byte_size --offset=read_offset_ bytes_

  read_primitive protobuf_type/int -> any:
    if protobuf_type == PROTOBUF_TYPE_DOUBLE:
      result := LITTLE_ENDIAN.float64 bytes_ read_offset_
      read_offset_ += 8
      return result
    else if protobuf_type == PROTOBUF_TYPE_FLOAT:
      result := LITTLE_ENDIAN.float32 bytes_ read_offset_
      read_offset_ += 4
      return result
    else if PROTOBUF_TYPE_INT64 <= protobuf_type <= PROTOBUF_TYPE_INT32 or
            PROTOBUF_TYPE_UINT64 <= protobuf_type <= PROTOBUF_TYPE_UINT32:
      return read_varint_
    else if PROTOBUF_TYPE_SINT64 <= protobuf_type <= PROTOBUF_TYPE_SINT32:
      result := read_varint_
      return (result >> 1) ^ -(result & 1)
    else if protobuf_type == PROTOBUF_TYPE_FIXED32 or protobuf_type == PROTOBUF_TYPE_SFIXED32:
      result := LITTLE_ENDIAN.int32 bytes_ read_offset_
      read_offset_ += 4
      return result
    else if protobuf_type == PROTOBUF_TYPE_FIXED64 or protobuf_type == PROTOBUF_TYPE_SFIXED64:
      result := LITTLE_ENDIAN.int64 bytes_ read_offset_
      read_offset_ += 8
      return result
    else if protobuf_type == PROTOBUF_TYPE_ENUM:
      return read_varint_
    else if protobuf_type == PROTOBUF_TYPE_BOOL:
      return read_varint_ != 0
    else if protobuf_type == PROTOBUF_TYPE_STRING:
      size := read_varint_
      result := bytes_.to_string read_offset_ read_offset_+size
      read_offset_ += size
      return result
    else if protobuf_type == PROTOBUF_TYPE_BYTES:
      size := read_varint_
      result := bytes_.copy read_offset_ read_offset_+size
      read_offset_ += size
      return result
    throw ERR_INVALID_TYPE

  read_array value_type/int array/List  [construct_value] -> List:
    prev_msg_end := msg_end
    is_packed := current_wire_type == PROTOBUF_WIRE_TYPE_LEN_DELIMITED and value_type < PROTOBUF_TYPE_STRING
    if is_packed:
      size := read_varint_
      msg_end = size + read_offset_
      while read_offset_ < msg_end:
        array.add construct_value.call
    else:
      array.add construct_value.call
    msg_end = prev_msg_end
    return array

  read_map map/Map [construct_key] [construct_value] -> Map:
    prev_msg_end := msg_end
    msg_end = read_varint_ + read_offset_
    while read_offset_ < msg_end:
      key := null
      read_field 1:
        key = construct_key.call
      read_field 2:
        value := construct_value.call
        if key != null:
          map[key] = value
    msg_end = prev_msg_end

    return map

  read_message [construct_message]:
    prev_msg_end := msg_end
    msg_end = prev_msg_end == null ? bytes_.size : read_varint_ + read_offset_

    while read_offset_ < msg_end:
      current_offset := read_offset_
      construct_message.call

      if current_offset == read_offset_:
        key := read_varint_
        wire_type := key & 0b111
        skip_element wire_type

    msg_end = prev_msg_end

  skip_element wire_type/int:
    if wire_type == PROTOBUF_WIRE_TYPE_VARINT:
      skip_varint_
    else if wire_type == PROTOBUF_TYPE_INT64:
      read_offset_ += 8
    else if wire_type == PROTOBUF_WIRE_TYPE_LEN_DELIMITED:
      read_offset_ += read_varint_
    else if wire_type == PROTOBUF_WIRE_TYPE_32BIT:
      read_offset_ + 4
    else:
      throw ERR_UNSUPPORTED_WIRE_TYPE

  read_field field_pos/int [construct_field]:
    if msg_end <= read_offset_:
      return
    key := peek_varint_
    wire_type := key & 0b111
    field := key >> 3
    if field_pos != field:
      return

    // skip the wire_type and field_pos.
    read_varint_

    prev_wire_type := current_wire_type
    current_wire_type = wire_type

    construct_field.call wire_type

    current_wire_type = prev_wire_type


class Writer_ implements Writer:
  // We reuse the buffer across writers. This works because serialization
  // cannot yield.
  static VARINT_BUFFER_/ByteArray := ByteArray 10

  // TODO: change the type of out to some Writer interface.
  out_/bytes.Buffer

  collection_field/int? := null
  writing_map/bool := false

  constructor .out_:

  reset:
    writing_map = false
    collection_field = null
    out_.clear

  buffer_ -> ByteArray:
    return out_.buffer

  write_key_ type/int as_field/int -> int:
    return write_varint_
      (as_field << 3) | type

  offset_reserved_ size:
    offset := out_.size
    out_.grow size
    return offset

  write_primitive protobuf_type/int value/any --oneof/bool=false --as_field/int?=null -> none:
    if as_field == null:
      as_field = collection_field
    can_skip := not oneof and as_field != null
    if protobuf_type == PROTOBUF_TYPE_DOUBLE:
      if can_skip and value == 0.0:
        return
      if as_field != null:
        write_key_ PROTOBUF_WIRE_TYPE_64BIT as_field
      offset := offset_reserved_ 8
      LITTLE_ENDIAN.put_float64 buffer_ offset value
    else if protobuf_type == PROTOBUF_TYPE_FLOAT:
      if can_skip and value == 0.0:
        return
      if as_field != null:
        write_key_ PROTOBUF_WIRE_TYPE_32BIT as_field
      offset := offset_reserved_ 4
      LITTLE_ENDIAN.put_float32 buffer_ offset value
    else if PROTOBUF_TYPE_INT64 <= protobuf_type <= PROTOBUF_TYPE_INT32 or
            PROTOBUF_TYPE_UINT64 <= protobuf_type <= PROTOBUF_TYPE_UINT32:
      if can_skip and value == 0:
        return
      if as_field != null:
        write_key_ PROTOBUF_WIRE_TYPE_VARINT as_field
      write_varint_ value
    else if PROTOBUF_TYPE_SINT64 <= protobuf_type <= PROTOBUF_TYPE_SINT32:
      if can_skip and value == 0:
        return
      if as_field != null:
        write_key_ PROTOBUF_WIRE_TYPE_VARINT as_field
      write_varint_ (value >> 63) ^ (value << 1)
    else if protobuf_type == PROTOBUF_TYPE_FIXED32 or protobuf_type == PROTOBUF_TYPE_SFIXED32:
      if can_skip and value == 0:
        return
      if as_field != null:
        write_key_ PROTOBUF_WIRE_TYPE_32BIT as_field
      offset := offset_reserved_ 4
      LITTLE_ENDIAN.put_int32 buffer_ offset value
    else if protobuf_type == PROTOBUF_TYPE_FIXED64 or protobuf_type == PROTOBUF_TYPE_SFIXED64:
      if can_skip and value == 0:
        return
      if as_field != null:
        write_key_ PROTOBUF_WIRE_TYPE_64BIT as_field
      offset := offset_reserved_ 8
      LITTLE_ENDIAN.put_int64 buffer_ offset value
    else if protobuf_type == PROTOBUF_TYPE_ENUM:
      if as_field != null and value == 0:
        return
      if as_field != null:
        write_key_ PROTOBUF_WIRE_TYPE_VARINT as_field
      write_varint_ value
    else if protobuf_type == PROTOBUF_TYPE_BOOL:
      if can_skip and not value:
        return
      if as_field != null:
        write_key_ PROTOBUF_WIRE_TYPE_VARINT as_field
      write_varint_ (value ? 1 : 0)
    else if protobuf_type == PROTOBUF_TYPE_STRING:
      if can_skip and value == "":
        return
      if as_field != null:
        write_key_ PROTOBUF_WIRE_TYPE_LEN_DELIMITED as_field
      write_varint_ value.size
      out_.write value
    else if protobuf_type == PROTOBUF_TYPE_BYTES:
      if can_skip and value.is_empty:
        return
      if as_field != null:
        write_key_ PROTOBUF_WIRE_TYPE_LEN_DELIMITED as_field
      write_varint_ value.size
      out_.write value
    else:
      throw ERR_UNSUPPORTED_TYPE

  write_array protobuf_value_type/int array/List --oneof/bool=false --as_field/int?=null [serialize_value] -> none:
    if as_field == null:
      as_field = collection_field

    should_pack := protobuf_value_type < PROTOBUF_TYPE_STRING
    size := 0

    if should_pack:
      size = size_array protobuf_value_type array

    if not oneof and as_field != null and array.is_empty:
      return

    curr_collection_field := collection_field
    if should_pack:
      // We have to null the collection field in this scenario, we want children
      // to be written as without the --as_field flag set and we might have an map element ancestor.
      collection_field = null
    else:
      collection_field = as_field

    if should_pack:
      write_key_ PROTOBUF_WIRE_TYPE_LEN_DELIMITED as_field
      write_varint_ size

    array.do serialize_value

    collection_field = curr_collection_field

  write_map protobuf_key_type/int protobuf_value_type/int map/Map --oneof/bool=false --as_field/int?=null [serialize_key] [serialize_value] -> none:
    if as_field == null:
      as_field = collection_field
    if not oneof and as_field != null and map.is_empty:
      return

    curr_collection_field := collection_field

    map.do: | k v |
      kv_size := protobuf_key_type == PROTOBUF_TYPE_MESSAGE ?
        size_embedded_message k.protobuf_size --as_field=1 :
        size_primitive protobuf_key_type k --as_field=1
      kv_size += protobuf_value_type == PROTOBUF_TYPE_MESSAGE ?
        size_embedded_message v.protobuf_size --as_field=2 :
        size_primitive protobuf_key_type v --as_field=2
      this.write_message_header (fakeMessage_.with 2 kv_size) --as_field=as_field
      collection_field = 1
      serialize_key.call k
      collection_field = 2
      serialize_value.call v

    collection_field = curr_collection_field

  write_message_header msg/Message --oneof/bool=false --as_field/int?=null -> none:
    if as_field == null:
      as_field = collection_field

    // We don't have to null the collection_field in this scenario.
    // All children of a message serialization will be with an --as_field set.

    // If this is the first object we don't need a header.
    if as_field == null:
      return

    size := msg.protobuf_size
    if size == 0:
      return
    write_key_ PROTOBUF_WIRE_TYPE_LEN_DELIMITED as_field
    write_varint_ size

  write_varint_ i/int -> int:
    size := varint.encode VARINT_BUFFER_ 0 i
    return out_.write VARINT_BUFFER_ 0 size

size_key_ field/int -> int:
  return varint.size (field << 3)

size_array protobuf_value_type/int array/List --as_field/int?=null -> int:
  if array.is_empty:
    return 0
  size := 0

  should_pack := protobuf_value_type < PROTOBUF_TYPE_STRING

  array.do:
    if should_pack:
      // Note we can never pack a type message
      size += size_primitive protobuf_value_type it
    else:
      size += protobuf_value_type == PROTOBUF_TYPE_MESSAGE ?
        size_embedded_message it.protobuf_size --as_field=as_field :
        size_primitive protobuf_value_type it --as_field=as_field

  if should_pack:
    return size_embedded_message size --as_field=as_field
  return size

size_map protobuf_key_type/int protobuf_value_type/int map/Map --as_field/int?=null  -> int:
  size := 0
  map.do: | k v |
    kv_size := protobuf_key_type == PROTOBUF_TYPE_MESSAGE ?
      size_embedded_message k.protobuf_size --as_field=1 :
      size_primitive protobuf_key_type k --as_field=1
    kv_size += protobuf_value_type == PROTOBUF_TYPE_MESSAGE ?
      size_embedded_message v.protobuf_size --as_field=2 :
      size_primitive protobuf_value_type v --as_field=2
    size += size_embedded_message kv_size  --as_field=as_field
  return size

size_embedded_message msg_size/int --as_field/int?=null -> int:
  if msg_size == 0:
    return 0
  if as_field == null:
    return msg_size
  return (size_key_ as_field) + (varint.size msg_size) + msg_size

size_primitive protobuf_type/int value/any --as_field/int?=null -> int:
  header_size := as_field != null ? (size_key_ as_field) : 0
  if protobuf_type == PROTOBUF_TYPE_DOUBLE:
    if value == 0.0:
      return 0
    return header_size + 8
  else if protobuf_type == PROTOBUF_TYPE_FLOAT:
    if value == 0.0:
      return 0
    return header_size + 4
  else if PROTOBUF_TYPE_INT64 <= protobuf_type <= PROTOBUF_TYPE_INT32 or
          PROTOBUF_TYPE_UINT64 <= protobuf_type <= PROTOBUF_TYPE_UINT32:
    if value == 0:
      return 0
    return header_size + (varint.size value)
  else if PROTOBUF_TYPE_SINT64 <= protobuf_type <= PROTOBUF_TYPE_SINT32:
    if value == 0:
      return 0
    return header_size + (varint.size ((value >> 63) ^ (value << 1)))
  else if protobuf_type == PROTOBUF_TYPE_FIXED32 or protobuf_type == PROTOBUF_TYPE_SFIXED32:
    if value == 0:
      return 0
    return header_size + 4
  else if protobuf_type == PROTOBUF_TYPE_FIXED64 or protobuf_type == PROTOBUF_TYPE_SFIXED64:
    if value == 0:
      return 0
    return header_size + 8
  else if protobuf_type == PROTOBUF_TYPE_ENUM:
    if value == 0:
      return 0
    return header_size + (varint.size value)
  else if protobuf_type == PROTOBUF_TYPE_BOOL:
    if not value:
      return 0
    return header_size + 1
  else if protobuf_type == PROTOBUF_TYPE_STRING:
    if value == "":
      return 0
      if value == 0:
    return header_size + (varint.size value.size) + value.size
  else if protobuf_type == PROTOBUF_TYPE_BYTES:
    if value.is_empty:
      return 0
    return header_size + (varint.size value.size) + value.size
  else:
    throw ERR_UNSUPPORTED_TYPE
