// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import io

/**
An exception indicating that a remote stub does not support a qXfer object.
*/
class UnsupportedQxfer:
  object-name/string
  annex/string

  /** Constructs an exception for the specified object and annex. */
  constructor .object-name .annex:

  stringify -> string:
    return "Unsupported qXfer $object-name/$annex"

/** Describes an RSP stop reply returned after execution stops. */
class StopReply:
  /** Contains the untouched stop-reply payload. */
  payload/string

  /** Contains the stop signal, when the reply provides one. */
  signal/int? := null

  /** Contains the stopped thread ID, when the reply provides one. */
  thread-id/string? := null

  constructor .payload:
    if payload.size >= 3 and (payload[0] == 'S' or payload[0] == 'T'):
      signal = parse-hex-byte_ payload[1..3]
    if payload.starts-with "T":
      fields := payload[3..].split ";"
      fields.do: | field/string |
        if field.starts-with "thread:": thread-id = field[7..]

/**
Implements a client for GDB's Remote Serial Protocol.

One client represents one ordered RSP byte stream. Calls are synchronous and
must not overlap.
*/
class Client:
  reader_/io.Reader
  writer_/io.Writer
  no-ack_/bool := false
  capabilities/Set := {}

  /**
  Constructs a client over a reader and writer.

  The caller retains ownership of the transport and is responsible for
  closing it.
  */
  constructor .reader_ .writer_:

  /** Negotiates capabilities and enters no-ack mode when supported. */
  initialize -> none:
    supported := request
        "qSupported:multiprocess+;qXfer:features:read+;qXfer:threads:read+"
    capabilities = {}
    (supported.to-string.split ";").do: capabilities.add it
    if capabilities.contains "QStartNoAckMode+":
      if (request "QStartNoAckMode").to-string != "OK":
        throw "GDB_NO_ACK_REJECTED"
      no-ack_ = true

  /** Sends one request and returns its decoded response payload. */
  request payload/string -> ByteArray:
    writer_.write (encode-packet payload.to-byte-array) --flush
    first/int? := null
    if not no-ack_:
      first = reader_.read-byte
      if first == '-': throw "GDB_REQUEST_CHECKSUM_REJECTED"
      if first == '+': first = null
    response := receive-packet_ first
    if not response.is-empty and response[0] == 'E':
      throw "GDB_REQUEST_FAILED: $(response.to-string)"
    return response

  /** Reads a complete object through chunked `qXfer` requests. */
  read-qxfer object-name/string annex/string -> ByteArray:
    offset := 0
    result := io.Buffer
    while true:
      response := request
          "qXfer:$object-name:read:$annex:$(offset.to-string --radix=16),1000"
      if response.is-empty or (response[0] != 'm' and response[0] != 'l'):
        throw (UnsupportedQxfer object-name annex)
      result.write response[1..]
      offset += response.size - 1
      if response[0] == 'l': return result.bytes

  /** Writes $bytes to the target at $address. */
  write-memory address/int bytes/ByteArray -> none:
    if address < 0: throw "INVALID_GDB_ADDRESS"
    response := request
        "M$(address.to-string --radix=16),$(bytes.size.to-string --radix=16):$(hex-encode_ bytes)"
    if response.to-string != "OK": throw "GDB_MEMORY_WRITE_REJECTED"

  /** Reads $length bytes from the target at $address. */
  read-memory address/int length/int -> ByteArray:
    if address < 0 or length < 0: throw "INVALID_GDB_MEMORY_RANGE"
    response := request
        "m$(address.to-string --radix=16),$(length.to-string --radix=16)"
    if response.size != length * 2: throw "INVALID_GDB_MEMORY_RESPONSE"
    return hex-decode_ response.to-string

  /** Installs a software breakpoint at $address. */
  insert-software-breakpoint address/int --kind/int=1 -> none:
    breakpoint-command_ "Z0," address kind

  /** Removes a software breakpoint at $address. */
  remove-software-breakpoint address/int --kind/int=1 -> none:
    breakpoint-command_ "z0," address kind

  /** Continues target execution and returns when the target stops. */
  continue-execution -> StopReply:
    response := request "c"
    if response.is-empty or
        (response[0] != 'S' and response[0] != 'T' and response[0] != 'W' and
         response[0] != 'X'):
      throw "INVALID_GDB_STOP_REPLY"
    return StopReply response.to-string

  breakpoint-command_ command/string address/int kind/int -> none:
    if address < 0 or kind <= 0: throw "INVALID_GDB_BREAKPOINT"
    response := request
        "$command$(address.to-string --radix=16),$(kind.to-string --radix=16)"
    if response.to-string != "OK": throw "GDB_BREAKPOINT_REJECTED"

  receive-packet_ first/int? -> ByteArray:
    byte := first or reader_.read-byte
    while byte != '$': byte = reader_.read-byte
    encoded := io.Buffer
    while true:
      byte = reader_.read-byte
      if byte == '#': break
      encoded.write-byte byte
    checksum-bytes := reader_.read-bytes 2
    expected := int.parse --radix=16 checksum-bytes.to-string
    actual := checksum_ encoded.bytes
    if actual != expected:
      if not no-ack_: writer_.write-byte '-' --flush
      throw "GDB_RESPONSE_CHECKSUM_MISMATCH"
    if not no-ack_: writer_.write-byte '+' --flush
    return decode-payload encoded.bytes

/** Encodes one unescaped GDB RSP $payload, including its checksum. */
encode-packet payload/ByteArray -> ByteArray:
  result := io.Buffer
  result.write-byte '$'
  result.write payload
  result.write-byte '#'
  value := checksum_ payload
  result.write-byte (hex-digit_ value >> 4)
  result.write-byte (hex-digit_ value & 0xf)
  return result.bytes

/** Decodes GDB escaping and run-length encoding from a packet $payload. */
decode-payload payload/ByteArray -> ByteArray:
  result := io.Buffer
  index := 0
  while index < payload.size:
    byte := payload[index]
    if byte == '}':
      index++
      if index >= payload.size: throw "TRUNCATED_GDB_ESCAPE"
      result.write-byte (payload[index] ^ 0x20)
    else if byte == '*':
      index++
      if index >= payload.size or result.size == 0:
        throw "INVALID_GDB_RUN_LENGTH"
      repeat := payload[index] - 29
      if repeat < 0: throw "INVALID_GDB_RUN_LENGTH"
      previous := result.backing-array[result.size - 1]
      repeat.repeat: result.write-byte previous
    else:
      result.write-byte byte
    index++
  return result.bytes

checksum_ bytes/ByteArray -> int:
  result := 0
  bytes.do: result = (result + it) & 0xff
  return result

hex-digit_ value/int -> int:
  return value < 10 ? '0' + value : 'a' + value - 10

hex-encode_ bytes/ByteArray -> string:
  result := ByteArray bytes.size * 2
  index := 0
  bytes.do: | byte/int |
    result[index * 2] = hex-digit_ byte >> 4
    result[index * 2 + 1] = hex-digit_ byte & 0xf
    index++
  return result.to-string

hex-decode_ value/string -> ByteArray:
  if (value.size & 1) != 0: throw "INVALID_GDB_HEX"
  result := ByteArray value.size / 2
  result.size.repeat:
    high := (hex-value_ value[it * 2]) << 4
    result[it] = high | (hex-value_ value[it * 2 + 1])
  return result

parse-hex-byte_ value/string -> int:
  if value.size != 2: throw "INVALID_GDB_STOP_REPLY"
  return ((hex-value_ value[0]) << 4) | (hex-value_ value[1])

hex-value_ rune/int -> int:
  if '0' <= rune <= '9': return rune - '0'
  if 'a' <= rune <= 'f': return rune - 'a' + 10
  if 'A' <= rune <= 'F': return rune - 'A' + 10
  throw "INVALID_GDB_HEX"
