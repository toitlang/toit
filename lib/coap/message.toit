// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import io

import .option

CODE-CLASS-SHIFT_ ::= 5

CODE-GET ::= (CODE-CLASS-REQUEST << CODE-CLASS-SHIFT_) | 1
CODE-POST ::= (CODE-CLASS-REQUEST << CODE-CLASS-SHIFT_) | 2
CODE-PUT ::= (CODE-CLASS-REQUEST << CODE-CLASS-SHIFT_) | 3
CODE-CONTENT ::= (CODE-CLASS-SUCCESS << CODE-CLASS-SHIFT_) | 5
CODE-GATEWAY-TIMEOUT ::= (CODE-CLASS-SERVER-ERROR << CODE-CLASS-SHIFT_) | 4
CODE-NOT-FOUND ::= (CODE-CLASS-CLIENT-ERROR << CODE-CLASS-SHIFT_) | 4

CODE-CLASS-REQUEST ::= 0
CODE-CLASS-SUCCESS ::= 2
CODE-CLASS-CLIENT-ERROR ::= 4
CODE-CLASS-SERVER-ERROR ::= 5

class Token:
  bytes     / ByteArray ::= ?
  hash-code / int ::= ?

  constructor .bytes:
    hash-code = bytes.size
    bytes.do: hash-code = 7 * hash-code + it

  operator== other/Token:
    if other is not Token: return false
    return bytes == other.bytes

  static create-random -> Token:
    return Token
      ByteArray 8: random & 0xff

class Message:
  static CODE-DETAIL-MASK_ ::= 0b11111
  static CODE-CLASS-MASK_ ::= 0b111

  static OPTION-DELTA-SHIFT_ ::= 4
  static OPTION-DELTA-MASK_ ::= 0b1111
  static OPTION-LENGTH-MASK_ ::= 0b1111

  static OPTION-1-BYTE-MARKER_ ::= 13
  static OPTION-2-BYTE-MARKER_ ::= 14
  static OPTION-2-BYTE-OFFSET_ ::= 269
  static OPTION-ERROR-MARKER_ ::= 15

  static PAYLOAD-MARKER_ ::= 0xff

  code := 0
  token/Token? := null
  payload/io.Reader? := null

  options := []

  is-empty: return code == 0

  code-class: return (code >> CODE-CLASS-SHIFT_) & CODE-CLASS-MASK_

  code-detail: return code & CODE-DETAIL-MASK_

  add-path path/string:
    if not path.starts-with "/": throw "FORMAT_ERROR"
    index := 1
    while index < path.size:
      to := path.index-of "/" index
      if to == -1: to = path.size
      options.add
        Option.string
          OPTION-URI-PATH
          path.copy index to
      index = to + 1

  path -> string:
    path := ""
    options.do:
      if it.number == OPTION-URI-PATH:
        path += "/" + it.as-string
    return path

  read-payload -> ByteArray:
    if not payload: return ByteArray 0
    buffer := io.Buffer.with-capacity payload.content-size
    buffer.write-from payload
    return buffer.bytes

  write-options_ buffer/io.Buffer:
    // TODO: Perform a stable sort instead?
    sorted := options.is-empty or options.is-sorted: | a b | a.number - b.number
    if not sorted: throw "UNSORTED_OPTIONS"

    last-number := 0
    options.do:
      delta := it.number - last-number
      last-number = it.number
      delta-bits := option-bits_ delta
      length := it.value.size
      length-bits := option-bits_ length
      buffer.write-byte
        (delta-bits & OPTION-DELTA-MASK_) << OPTION-DELTA-SHIFT_
          | length-bits & OPTION-LENGTH-MASK_
      option-write-ext_ delta-bits delta buffer
      option-write-ext_ length-bits length buffer
      buffer.write it.value

  write-payload_ buffer/io.Buffer:
    if payload:
      buffer.write-from payload

  parse-options_ msg-length/int reader/io.Reader -> int:
    read := 0
    number := 0
    while read < msg-length:
      byte := reader.read-byte
      read++
      if byte == PAYLOAD-MARKER_: return msg-length - read

      // Read delta (and apply to last message number).
      delta := (byte >> OPTION-DELTA-SHIFT_) & OPTION-DELTA-MASK_
      if delta == OPTION-1-BYTE-MARKER_:
        if msg-length < read + 1: throw "OUT_OF_RANGE"
        delta += reader.read-byte
        read++
      else if delta == OPTION-2-BYTE-MARKER_:
        if msg-length < read + 2: throw "OUT_OF_RANGE"
        data := reader.big-endian.read-uint16
        read += 2
        delta =  OPTION-2-BYTE-OFFSET_ + data
      else if delta == OPTION-ERROR-MARKER_:
        throw "FORMAT_ERROR"
      number += delta

      // Read length.
      length := byte & OPTION-LENGTH-MASK_
      if length == OPTION-1-BYTE-MARKER_:
        if msg-length < read + 1: throw "OUT_OF_RANGE"
        length += reader.read-byte
        read++
      else if length == OPTION-2-BYTE-MARKER_:
        if msg-length < read + 2: throw "OUT_OF_RANGE"
        data := reader.big-endian.read-uint16
        read += 2
        length = OPTION-2-BYTE-OFFSET_ + data
      else if length == OPTION-ERROR-MARKER_:
        throw "FORMAT_ERROR"
      if msg-length < read + length: throw "OUT_OF_RANGE"
      options.add
        Option.bytes
          number
          reader.read-bytes length
      read += length
    return 0

  static option-bits_ value:
    if value < OPTION-1-BYTE-MARKER_: return value
    if value < OPTION-2-BYTE-OFFSET_: return OPTION-1-BYTE-MARKER_
    return OPTION-2-BYTE-MARKER_

  static option-write-ext_ bits value buffer/io.Buffer:
    if bits == OPTION-1-BYTE-MARKER_:
      buffer.write-byte value - OPTION-1-BYTE-MARKER_
    else if bits == OPTION-2-BYTE-MARKER_:
      buffer.big-endian.write-uint16 (value - OPTION-2-BYTE-OFFSET_)
