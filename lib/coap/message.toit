// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import binary
import bytes
import reader

import .option

CODE_CLASS_SHIFT_ ::= 5

CODE_GET ::= (CODE_CLASS_REQUEST << CODE_CLASS_SHIFT_) | 1
CODE_POST ::= (CODE_CLASS_REQUEST << CODE_CLASS_SHIFT_) | 2
CODE_PUT ::= (CODE_CLASS_REQUEST << CODE_CLASS_SHIFT_) | 3
CODE_CONTENT ::= (CODE_CLASS_SUCCESS << CODE_CLASS_SHIFT_) | 5
CODE_GATEWAY_TIMEOUT ::= (CODE_CLASS_SERVER_ERROR << CODE_CLASS_SHIFT_) | 4
CODE_NOT_FOUND ::= (CODE_CLASS_CLIENT_ERROR << CODE_CLASS_SHIFT_) | 4

CODE_CLASS_REQUEST ::= 0
CODE_CLASS_SUCCESS ::= 2
CODE_CLASS_CLIENT_ERROR ::= 4
CODE_CLASS_SERVER_ERROR ::= 5

class Token:
  bytes     / ByteArray ::= ?
  hash_code / int ::= ?

  constructor .bytes:
    hash_code = bytes.size
    bytes.do: hash_code = 7 * hash_code + it

  operator== other/Token:
    if other is not Token: return false
    return bytes == other.bytes

  static create_random -> Token:
    return Token
      ByteArray 8: random & 0xff

class Message:
  static CODE_DETAIL_MASK_ ::= 0b11111
  static CODE_CLASS_MASK_ ::= 0b111

  static OPTION_DELTA_SHIFT_ ::= 4
  static OPTION_DELTA_MASK_ ::= 0b1111
  static OPTION_LENGTH_MASK_ ::= 0b1111

  static OPTION_1_BYTE_MARKER_ ::= 13
  static OPTION_2_BYTE_MARKER_ ::= 14
  static OPTION_2_BYTE_OFFSET_ ::= 269
  static OPTION_ERROR_MARKER_ ::= 15

  static PAYLOAD_MARKER_ ::= 0xff

  code := 0
  token/Token? := null
  payload/reader.SizedReader? := null

  options := []

  is_empty: return code == 0

  code_class: return (code >> CODE_CLASS_SHIFT_) & CODE_CLASS_MASK_

  code_detail: return code & CODE_DETAIL_MASK_

  add_path path/string:
    if not path.starts_with "/": throw "FORMAT_ERROR"
    index := 1
    while index < path.size:
      to := path.index_of "/" index
      if to == -1: to = path.size
      options.add
        Option.string
          OPTION_URI_PATH
          path.copy index to
      index = to + 1

  path -> string:
    path := ""
    options.do:
      if it.number == OPTION_URI_PATH:
        path += "/" + it.as_string
    return path

  read_payload -> ByteArray:
    if not payload: return ByteArray 0
    buffer := bytes.Buffer.with_initial_size payload.size
    buffer.write_from payload
    return buffer.buffer

  write_options_ buffer/bytes.Buffer:
    // TODO: Perform a stable sort instead?
    sorted := options.is_empty or options.is_sorted: | a b | a.number - b.number
    if not sorted: throw "UNSORTED_OPTIONS"

    last_number := 0
    options.do:
      delta := it.number - last_number
      last_number = it.number
      delta_bits := option_bits_ delta
      length := it.value.size
      length_bits := option_bits_ length
      buffer.write_byte
        (delta_bits & OPTION_DELTA_MASK_) << OPTION_DELTA_SHIFT_
          | length_bits & OPTION_LENGTH_MASK_
      option_write_ext_ delta_bits delta buffer
      option_write_ext_ length_bits length buffer
      buffer.write it.value

  write_payload_ buffer/bytes.Buffer:
    if payload:
      buffer.write_from payload

  parse_options_ msg_length/int reader/reader.BufferedReader -> int:
    read := 0
    number := 0
    while read < msg_length:
      byte := reader.read_byte
      read++
      if byte == PAYLOAD_MARKER_: return msg_length - read

      // Read delta (and apply to last message number).
      delta := (byte >> OPTION_DELTA_SHIFT_) & OPTION_DELTA_MASK_
      if delta == OPTION_1_BYTE_MARKER_:
        if msg_length < read + 1: throw "OUT_OF_RANGE"
        delta += reader.read_byte
        read++
      else if delta == OPTION_2_BYTE_MARKER_:
        if msg_length < read + 2: throw "OUT_OF_RANGE"
        data := reader.read_bytes 2
        read += 2
        delta =  OPTION_2_BYTE_OFFSET_ + (binary.BIG_ENDIAN.uint16 data 0)
      else if delta == OPTION_ERROR_MARKER_:
        throw "FORMAT_ERROR"
      number += delta

      // Read length.
      length := byte & OPTION_LENGTH_MASK_
      if length == OPTION_1_BYTE_MARKER_:
        if msg_length < read + 1: throw "OUT_OF_RANGE"
        length += reader.read_byte
        read++
      else if length == OPTION_2_BYTE_MARKER_:
        if msg_length < read + 2: throw "OUT_OF_RANGE"
        data := reader.read_bytes 2
        read += 2
        length = OPTION_2_BYTE_OFFSET_ + (binary.BIG_ENDIAN.uint16 data 0)
      else if length == OPTION_ERROR_MARKER_:
        throw "FORMAT_ERROR"
      if msg_length < read + length: throw "OUT_OF_RANGE"
      options.add
        Option.bytes
          number
          reader.read_bytes length
      read += length
    return 0

  static option_bits_ value:
    if value < OPTION_1_BYTE_MARKER_: return value
    if value < OPTION_2_BYTE_OFFSET_: return OPTION_1_BYTE_MARKER_
    return OPTION_2_BYTE_MARKER_

  static option_write_ext_ bits value buffer:
    if bits == OPTION_1_BYTE_MARKER_:
      buffer.write_byte value - OPTION_1_BYTE_MARKER_
    else if bits == OPTION_2_BYTE_MARKER_:
      array := ByteArray 2
      binary.BIG_ENDIAN.put_uint16 array 0 value - OPTION_2_BYTE_OFFSET_
      buffer.write array
