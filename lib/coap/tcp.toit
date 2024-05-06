// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import io
import monitor

import .client
import .message
import .transport

CODE-CSM ::= (CODE-CLASS-SIGNALING-CODES << CODE-CLASS-SHIFT_) | 1
CODE-PING ::= (CODE-CLASS-SIGNALING-CODES << CODE-CLASS-SHIFT_) | 2
CODE-PONG ::= (CODE-CLASS-SIGNALING-CODES << CODE-CLASS-SHIFT_) | 3

CODE-CLASS-SIGNALING-CODES ::= 7

class SizedReader_ extends io.Reader:
  done_/monitor.Latch ::= monitor.Latch
  transport_/Transport
  reader_/io.Reader
  content-size/int

  remaining_/int := ?

  constructor .transport_ .reader_ .content-size:
    remaining_ = content-size
    if content-size == 0: done_.set null

  read_ -> ByteArray?:
    if remaining_ == 0:
      done_.set null
      return null
    // We loop so we get to return the socket's closed error instead
    // of some other one.
    try:
      with-timeout Client.DEFAULT-MAX-DELAY:
        b := reader_.read --max-size=remaining_
        remaining_ -= b.size
        return b
    finally: | is-exception _ |
      if is-exception: transport_.close
    unreachable

class TcpTransport implements Transport:
  socket_ ::= ?
  reader_/io.Reader ::= ?
  writer_/io.Writer ::= ?

  current-sized-reader_/SizedReader_? := null

  constructor .socket_ --send-csm=true:
    socket_.no-delay = true
    reader_ = socket_.in
    writer_ = socket_.out

    if send-csm:
      csm-msg := new-message as TcpMessage
      csm-msg.code = CODE-CSM
      write csm-msg

  write msg/TcpMessage:
    writer_.write msg.header
    if msg.payload: writer_.write-from msg.payload

  read -> Response?:
    while true:
      if current-sized-reader_:
        current-sized-reader_.done_.get
        current-sized-reader_ = null
      msg := TcpMessage.parse this reader_
      if not msg: return null
      if msg.code == CODE-CSM:
        while msg.payload.read:
        // TODO: Process values.
      else:
        current-sized-reader_ = msg.payload as SizedReader_
        return Response.message msg

  close:
    // Be sure to abort any ongoing reading.
    if current-sized-reader_: current-sized-reader_.done_.set null
    socket_.close

  new-message --reliable=true -> Message:
    // Ignore reliable flag - all messages are reliable by default.
    return TcpMessage

  reliable -> bool: return true

  mtu -> int: return socket_.mtu

class TcpMessage extends Message:
  static LENGTH-SHIFT_ ::= 4
  static LENGTH-MASK_ ::= 0b1111
  static TKL-MASK_ ::= 0b1111

  static _1-BYTE-MARKER ::= 13
  static _1-BYTE-OFFSET ::= 13
  static _2-BYTE-MARKER ::= 14
  static _2-BYTE-OFFSET ::= 269
  static _4-BYTE-MARKER ::= 15
  static _4-BYTE-OFFSET ::= 65805

  header -> ByteArray:
    // TODO(anders): Get size without creating the buffer?
    optionsData := io.Buffer
    write-options_ optionsData

    size := optionsData.size
    if payload: size += payload.content-size + 1

    header := io.Buffer
    // Reserve a byte for data0.
    header.write-byte 0
    data0 := (token ? token.bytes.size : 0) & TKL-MASK_
    if size >= _4-BYTE-OFFSET:
      data0 |= _4-BYTE-MARKER << LENGTH-SHIFT_
      header.big-endian.write-uint32 (size - _4-BYTE-OFFSET)
    else if size >= _2-BYTE-OFFSET:
      data0 |= _2-BYTE-MARKER << LENGTH-SHIFT_
      header.big-endian.write-uint16 (size - _2-BYTE-OFFSET)
    else if size >= _1-BYTE-OFFSET:
      data0 |= _1-BYTE-MARKER << LENGTH-SHIFT_
      header.write-byte size - _1-BYTE-OFFSET
    else:
      data0 |= size << LENGTH-SHIFT_

    header.write-byte code
    if token: header.write token.bytes

    header.write optionsData.bytes 0 optionsData.size

    if payload:
      header.write-byte Message.PAYLOAD-MARKER_

    data := header.bytes
    data[0] = data0
    return data

  // Parse a Stream message from the reader.
  static parse transport/Transport reader/io.Reader -> TcpMessage?:
    if not reader.try-ensure-buffered 1: return null
    data0 := reader.read-byte
    length := (data0 >> LENGTH-SHIFT_) & LENGTH-MASK_
    if length == _4-BYTE-MARKER:
      length = _4-BYTE-OFFSET + reader.big-endian.read-uint32
    else if length == _2-BYTE-MARKER:
      length = _2-BYTE-OFFSET + reader.big-endian.read-uint16
    else if length == _1-BYTE-MARKER:
      length = _1-BYTE-OFFSET + reader.read-byte
    msg := TcpMessage
    msg.code = reader.read-byte
    // Token length (0-8 bytes).
    tkl := data0 & TKL-MASK_
    if tkl > 8: throw "FORMAT_ERROR"
    if tkl > 0:
      msg.token = Token
        reader.read-bytes tkl
    rem := msg.parse-options_ length reader
    msg.payload = SizedReader_ transport reader rem
    return msg
