// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import reader show Reader
import http
import encoding.base64 as base64
import crypto.sha1 as crypto

// Perform the calculation from RFC 6455 to verify an HTTP->WebSockets upgrade.
magic_accept_ key:
  return base64.encode (crypto.sha1 key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")

class WebSocketClient extends WebSocket:
  /**
  Upgrades a GET request to a WebSocket.
  Once you have upgraded a connection and request like this you can
    no longer use the original connection for regular HTTP.
  */
  constructor http_connection/http.Connection request/http.Request:
    request.headers.set "Connection" "Upgrade"
    request.headers.set "Upgrade" "websocket"
    random_bytes := ByteArray 16: random 0x100
    magic_key := base64.encode random_bytes
    request.headers.set "Sec-WebSocket-Key" magic_key
    request.headers.set "Sec-Websocket-Version" "13"
    // TODO: Set origin.

    response := request.send
    FAILED := "FAILED_UPGRADING_CONNECTION"
    if response.status_code != 101:
      throw "$FAILED, got status `$(response.status_code) $(response.status_message)`"
    if (response.headers.single "Sec-WebSocket-Accept") != (magic_accept_ magic_key):
      throw "$FAILED, Sec-WebSocket-Accept did not match"

    socket := response.detach
    super.protected_ http_connection.reader socket true

class WebSocketServer extends WebSocket:
  /**
  Upgrades a GET request to a WebSocket.
  Once you have upgraded a connection and request like this you can
    no longer use the original connection for regular HTTP.
  */
  constructor http_connection/http.Connection request/http.Request:
    if not request.should_web_socket_upgrade: throw "Request is not being upgraded to websocket"

    magic_key := request.headers.single "Sec-WebSocket-Key"
    if not magic_key: throw "Missing `Sec-WebSocket-Key` header"

    // TODO: Validate origin.

    response := request.response
    response.status_code = 101
    response.status_message = "Switching Protocols"
    response.headers.set "Connection" "Upgrade"
    response.headers.set "Upgrade" "websocket"
    response.headers.set "Sec-WebSocket-Accept" (magic_accept_ magic_key)

    response.send

    socket := response.detach
    super.protected_ http_connection.reader socket false

class WebSocket:
  reader_ := ?
  writer_ := ?
  send_masked_ := false
  identity_hash_code_ := random

  static OPCODE_MASK_ ::= 0xf
  static PAYLOAD_LENGTH_MASK_ ::= 0x7f
  static MASK_MASK_ ::= 0x80
  static CONTINUATION_ ::= 0
  static TEXT_ ::= 1
  static BINARY_ ::= 2
  static CLOSE_ ::= 8
  static PING_ ::= 9
  static PONG_ ::= 10
  static FIN_ ::= 0x80
  static TWO_BYTE_LENGTH_ ::= 126
  static EIGHT_BYTE_LENGTH_ ::= 127

  constructor.protected_ .reader_ .writer_ .send_masked_:

  /**
  Returns a string or a byte array, depending on whether the sender marked
    the packet as TEXT or BINARY.
  */
  read:
    return read_

  /**
  Writes a single message.
  $data can be a string or a byte array.
  */
  write data -> none:
    write_ data (data is string ? TEXT_ : BINARY_)

  /// Writes a CLOSE packet to the WebSocket, then closes it.
  close_write:
    write_ "" CLOSE_
    writer_.close_write

  close -> none:
    if writer_.is_connected:
      writer_.close

  is_connected -> bool:
    return writer_.is_connected

  peer_port -> int:
    return writer_.peer_port

  peer_address:
    return writer_.peer_address

  hash_code -> int:
    return identity_hash_code_

  write_ payload opcode:  // Payload can be a string or a byte array.
    size := payload.size
    header_size := 2 + (size >= TWO_BYTE_LENGTH_ ? 2 : 0) + (size > 0xffff ? 6 : 0)
    if send_masked_: header_size += 4
    header := ByteArray header_size
    header[0] = FIN_ | (opcode & OPCODE_MASK_)
    if size < TWO_BYTE_LENGTH_:
      header[1] = size | (send_masked_ ? MASK_MASK_ : 0)
    else if size <= 0xffff:
      header[1] = TWO_BYTE_LENGTH_ | (send_masked_ ? MASK_MASK_ : 0)
      header[2] = size >> 8
      header[3] = size & 0xff
    else:
      header[1] = EIGHT_BYTE_LENGTH_ | (send_masked_ ? MASK_MASK_ : 0)
      header[2] = header[3] = header[4] = header[5] = 0
      header[6] = (size >> 24) & 0xff
      header[7] = (size >> 16) & 0xff
      header[8] = (size >> 8) & 0xff
      header[9] = (size >> 0) & 0xff
    if send_masked_:
      4.repeat: header[header_size - 1 - it] = random 0x100

    writer_.write header

    if send_masked_:
      masked := ByteArray payload.size
      mask_offset := header_size - 4
      for i := 0; i < payload.size; i++:
        byte := payload[i]
        if not byte:
          // If we got null then we are dealing with a string that has
          // non-ASCII in it.  Copy the raw bytes from this point to the byte
          // array and switch to in-place masking.
          i--  // Step back one to handle the non-ASCII character correctly.
          payload.write_to_byte_array masked i size i  // Copy raw UTF-8 out of string.
          payload = masked  // From now on we are masking in place.
          byte = payload[i]
        masked[i] = byte ^ header[mask_offset + (i & 3)]
      payload = masked

    writer_.write payload

  // Read until message incoming message is received.
  read_:
    while true:
      if not reader_.can_ensure 2:
        writer_.close
        return null

      if ((reader_.byte 0) == 'G' and (reader_.byte 1) == 'E'):
        throw "HTTP_ON_WEB_SOCKETS_ERROR"

      if ((reader_.byte 0) & FIN_) != FIN_:
        throw "NON_FIN_MESSAGES_NOT_SUPPORTED"

      size_field := (reader_.byte 1) & PAYLOAD_LENGTH_MASK_
      masked := ((reader_.byte 1) & MASK_MASK_) != 0
      header_size := masked ? 6 : 2
      if size_field == TWO_BYTE_LENGTH_: header_size += 2
      if size_field == EIGHT_BYTE_LENGTH_: header_size += 8

      reader_.ensure header_size
      size := size_field
      if size_field == TWO_BYTE_LENGTH_:
        size = ((reader_.byte 2) << 8) + (reader_.byte 3)
      else if size_field == EIGHT_BYTE_LENGTH_:
        if (reader_.byte 2) != 0 or (reader_.byte 3) != 0 or (reader_.byte 4) != 0 or (reader_.byte 5) != 0:
          throw "OVERSIZED_PACKET"
        size = ((reader_.byte 6) << 24) + ((reader_.byte 7) << 16) + ((reader_.byte 8) << 8) + (reader_.byte 9)

      opcode := (reader_.byte 0) & OPCODE_MASK_

      mask := null
      if masked:
        reader_.skip header_size - 4
        mask = reader_.read_bytes 4
      else:
        reader_.skip header_size

      reader_.ensure size

      payload := get_payload_ size mask (opcode == TEXT_)
      if opcode == PING_:
        write_ payload PONG_
      else if opcode == PONG_:
        null
      else if opcode == TEXT_ or opcode == BINARY_:
        return payload
      else if opcode == CONTINUATION_:
        throw "FRAGMENTED_MESSAGES_NOT_SUPPORTED"
      else if opcode == CLOSE_:
        return null
      else:
        throw "UNKNOWN MESSAGE_OPCODE_RECEIVED"

  get_payload_ size mask is_string_type:
    if not mask:
      if is_string_type:
        return reader_.read_string size
      else:
        return reader_.read_bytes size

    // mask_offset := header_size - 4
    payload := reader_.read_bytes size

    size.repeat:
      payload[it] ^= mask[it & 3] // (byte mask_offset + (it & 3))
    if not is_string_type:
      return payload
    return payload.to_string
