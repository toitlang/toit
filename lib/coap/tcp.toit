// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import bytes
import binary
import writer
import reader
import monitor

import .client
import .message
import .transport

CODE_CSM ::= (CODE_CLASS_SIGNALING_CODES << CODE_CLASS_SHIFT_) | 1
CODE_PING ::= (CODE_CLASS_SIGNALING_CODES << CODE_CLASS_SHIFT_) | 2
CODE_PONG ::= (CODE_CLASS_SIGNALING_CODES << CODE_CLASS_SHIFT_) | 3

CODE_CLASS_SIGNALING_CODES ::= 7

class Reader_ implements reader.SizedReader:
  done_/monitor.Latch ::= monitor.Latch
  transport_/Transport
  reader_/reader.BufferedReader
  size/int

  rem_/int := ?

  constructor .transport_ .reader_ .size:
    rem_ = size
    if size == 0: done_.set null

  read -> ByteArray?:
    if rem_ == 0:
      done_.set null
      return null
    // We loop so we get to return the socket's closed error instead
    // of some other one.
    try:
      with_timeout Client.DEFAULT_MAX_DELAY:
        b := reader_.read --max_size=rem_
        rem_ -= b.size
        return b
    finally: | is_exception _ |
      if is_exception: transport_.close
    unreachable

class TcpTransport implements Transport:
  socket_ ::= ?
  reader_/reader.BufferedReader ::= ?
  writer_/writer.Writer ::= ?

  current_reader_/Reader_? := null

  constructor .socket_ --send_csm=true:
    socket_.no_delay = true
    reader_ = reader.BufferedReader socket_
    writer_ = writer.Writer socket_

    if send_csm:
      csm_msg := new_message as TcpMessage
      csm_msg.code = CODE_CSM
      write csm_msg

  write msg/TcpMessage:
    writer_.write msg.header
    if msg.payload: writer_.write_from msg.payload

  read -> Response?:
    while true:
      if current_reader_:
        current_reader_.done_.get
        current_reader_ = null
      msg := TcpMessage.parse this reader_
      if not msg: return null
      if msg.code == CODE_CSM:
        while msg.payload.read:
        // TODO: Process values.
      else:
        current_reader_ = msg.payload as Reader_
        return Response.message msg

  close:
    // Be sure to abort any ongoing reading.
    if current_reader_: current_reader_.done_.set null
    socket_.close

  new_message --reliable=true -> Message:
    // Ignore reliable flag - all messages are reliable by default.
    return TcpMessage

  reliable -> bool: return true

  mtu -> int: return socket_.mtu

class TcpMessage extends Message:
  static LENGTH_SHIFT_ ::= 4
  static LENGTH_MASK_ ::= 0b1111
  static TKL_MASK_ ::= 0b1111

  static _1_BYTE_MARKER ::= 13
  static _1_BYTE_OFFSET ::= 13
  static _2_BYTE_MARKER ::= 14
  static _2_BYTE_OFFSET ::= 269
  static _4_BYTE_MARKER ::= 15
  static _4_BYTE_OFFSET ::= 65805

  header -> ByteArray:
    // TODO(anders): Get size without creating the buffer?
    optionsData := bytes.Buffer
    write_options_ optionsData

    size := optionsData.size
    if payload: size += payload.size + 1

    header := bytes.Buffer
    // Reserve a byte for data0.
    header.put_byte 0
    data0 := (token ? token.bytes.size : 0) & TKL_MASK_
    if size >= _4_BYTE_OFFSET:
      data0 |= _4_BYTE_MARKER << LENGTH_SHIFT_
      array := ByteArray 4
      binary.BIG_ENDIAN.put_uint32 array 0 size - _4_BYTE_OFFSET
      header.write array
    else if size >= _2_BYTE_OFFSET:
      data0 |= _2_BYTE_MARKER << LENGTH_SHIFT_
      array := ByteArray 2
      binary.BIG_ENDIAN.put_uint16 array 0 size - _2_BYTE_OFFSET
      header.write array
    else if size >= _1_BYTE_OFFSET:
      data0 |= _1_BYTE_MARKER << LENGTH_SHIFT_
      header.put_byte size - _1_BYTE_OFFSET
    else:
      data0 |= size << LENGTH_SHIFT_

    header.put_byte code
    if token: header.write token.bytes

    header.write optionsData.buffer 0 optionsData.size

    if payload:
      header.put_byte Message.PAYLOAD_MARKER_

    data := header.bytes
    data[0] = data0
    return data

  // Parse a Stream message from the reader.
  static parse transport/Transport reader/reader.BufferedReader -> TcpMessage?:
    if not reader.can_ensure 1: return null
    data0 := reader.read_byte
    length := (data0 >> LENGTH_SHIFT_) & LENGTH_MASK_
    if length == _4_BYTE_MARKER:
      length = _4_BYTE_OFFSET +
        binary.BIG_ENDIAN.uint32 (reader.read_bytes 4) 0
    else if length == _2_BYTE_MARKER:
      length = _2_BYTE_OFFSET +
        binary.BIG_ENDIAN.uint16 (reader.read_bytes 2) 0
    else if length == _1_BYTE_MARKER:
      length = _1_BYTE_OFFSET + reader.read_byte
    msg := TcpMessage
    msg.code = reader.read_byte
    // Token length (0-8 bytes).
    tkl := data0 & TKL_MASK_
    if tkl > 8: throw "FORMAT_ERROR"
    if tkl > 0:
      msg.token = Token
        reader.read_bytes tkl
    rem := msg.parse_options_ length reader
    msg.payload = Reader_ transport reader rem
    return msg
