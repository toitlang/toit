// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
Implementation of the XMODEM-1K file transfer protocol.
*/

import writer
import uart
import crypto.crc16 as crypto

/**
Writer for writing data in the XMODEM-1K format on the UART port.
*/
class Writer:
  static MAX_RETRY_/int ::= 3
  static RETRY_DELAY_/Duration ::= Duration --ms=500
  static ACK_/int ::= 0x06
  static NAK_/int ::= 0x15

  uart_/uart.Port
  writer_/writer.Writer
  buffer_ ::= Buffer

  constructor .uart_:
    writer_ = writer.Writer uart_
    wait_for_ready_

  write data:
    buffer_.next data
    write_package_ buffer_.to_byte_array

  done:
    write_package_ buffer_.eot

  write_package_ data/ByteArray:
    MAX_RETRY_.repeat:
      writer_.write data
      r := uart_.read
      if r.size != 1: throw "INVALID XMODEL RESPONSE: $r"
      if r[0] == ACK_: return
      if r[0] != NAK_: throw "INVALID XMODEL RESPONSE: $r"

      sleep RETRY_DELAY_

    throw "ERROR AFTER $MAX_RETRY_ RETRIES"

  wait_for_ready_:
    r := uart_.read
    if r.size == 1 and r[0] == 'C': return
    throw "INVALID XMODEL INIT: $r"

/**
Reusable buffer object for packing data in the XMODEM-1K format, by adding a header.

Note that only the last packet should be less than DATA_SIZE.
*/
class Buffer:
  static DATA_SIZE/int ::= 1024
  static DATA_OFFSET_/int ::= 3
  static STX_/int ::= 0x02
  static CTRL_Z_/int ::= 0x1A
  static EOT_/int ::= 0x04

  buffer_ ::= ByteArray DATA_SIZE + 5
  packet_no_ := 1

  next data/ByteArray:
    buffer_[0] = STX_
    buffer_[1] = packet_no_
    buffer_[2] = ~packet_no_
    buffer_.replace DATA_OFFSET_ data
    buffer_.fill --from=(DATA_OFFSET_ + data.size) --to=(DATA_OFFSET_ + DATA_SIZE) CTRL_Z_

    crc := crypto.crc16 buffer_ DATA_OFFSET_ DATA_OFFSET_ + DATA_SIZE

    // Note that bytes are swapped, little -> big endian.
    buffer_[DATA_OFFSET_ + DATA_SIZE] = crc[1]
    buffer_[DATA_OFFSET_ + DATA_SIZE + 1] = crc[0]

    packet_no_++

  to_byte_array: return buffer_

  eot: return ByteArray 1: EOT_
