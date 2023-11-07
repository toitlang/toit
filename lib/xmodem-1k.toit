// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
Implementation of the XMODEM-1K file transfer protocol.
*/

import uart
import crypto.checksum
import crypto.crc

/**
Writer for writing data in the XMODEM-1K format on the UART port.

Deprecated.
*/
class Writer:
  static MAX-RETRY_/int ::= 3
  static RETRY-DELAY_/Duration ::= Duration --ms=500
  static ACK_/int ::= 0x06
  static NAK_/int ::= 0x15

  uart_/uart.Port
  buffer_ ::= Buffer

  constructor .uart_:
    wait-for-ready_

  write data:
    buffer_.next data
    write-package_ buffer_.to-byte-array

  done:
    write-package_ buffer_.eot

  write-package_ data/ByteArray:
    MAX-RETRY_.repeat:
      uart_.out.write data
      r := uart_.in.read
      if r.size != 1: throw "INVALID XMODEL RESPONSE: $r"
      if r[0] == ACK_: return
      if r[0] != NAK_: throw "INVALID XMODEL RESPONSE: $r"

      sleep RETRY-DELAY_

    throw "ERROR AFTER $MAX-RETRY_ RETRIES"

  wait-for-ready_:
    r := uart_.in.read
    if r.size == 1 and r[0] == 'C': return
    throw "INVALID XMODEL INIT: $r"

/**
Reusable buffer object for packing data in the XMODEM-1K format, by adding a header.

Note that only the last packet should be less than DATA_SIZE.

Deprecated.
*/
class Buffer:
  static DATA-SIZE/int ::= 1024
  static DATA-OFFSET_/int ::= 3
  static STX_/int ::= 0x02
  static CTRL-Z_/int ::= 0x1A
  static EOT_/int ::= 0x04

  buffer_ ::= ByteArray DATA-SIZE + 5
  packet-no_ := 1

  next data/ByteArray:
    buffer_[0] = STX_
    buffer_[1] = packet-no_
    buffer_[2] = ~packet-no_
    buffer_.replace DATA-OFFSET_ data
    END ::= DATA-OFFSET_ + DATA-SIZE
    buffer_.fill --from=(DATA-OFFSET_ + data.size) --to=END CTRL-Z_

    buffer_.replace
        END
        checksum.checksum crc.Crc16Xmodem buffer_ DATA-OFFSET_ END

    packet-no_++

  to-byte-array: return buffer_

  eot: return ByteArray 1 --filler=EOT_
