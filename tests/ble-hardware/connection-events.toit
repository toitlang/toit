// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.transport
import io

// Test-only recorder. Retains public connection metadata, never packet bodies.
// Recording uses fixed storage and performs no printing or formatting.
class ConnectionEvents implements transport.Transport:
  radio_/transport.Transport
  records_/ByteArray ::= ByteArray (32 * 16)
  count/int := 0

  constructor .radio_:

  receive -> ByteArray:
    packet := radio_.receive
    record packet
    return packet

  send packet/ByteArray -> none:
    radio_.send packet
    record-send packet

  send-if packet/ByteArray [allowed] -> bool:
    sent := radio_.send-if packet allowed
    if sent: record-send packet
    return sent
  close -> none: radio_.close

  // Selected public command metadata only. Never retain addresses or payloads.
  selected_ opcode/int -> bool:
    return opcode == 0x0c03 or opcode == 0x200a or opcode == 0x200d or
        opcode == 0x200e or opcode == 0x2043 or opcode == 0x0406

  record-send packet/ByteArray -> none:
    if packet.size < 4 or packet[0] != 1 or packet[3] != packet.size - 4: return
    opcode := io.LITTLE-ENDIAN.uint16 packet 1
    if not (selected_ opcode): return
    detail := opcode == 0x200a and packet.size == 5 ? packet[4] : 0
    // Kind0x80 means transport acceptance, not controller command completion.
    append_ 0x80 0 opcode detail

  record packet/ByteArray -> none:
    if packet.size < 3 or packet[0] != 4 or packet[2] != packet.size - 3: return
    kind := 0
    status := 0
    handle := 0
    detail := 0
    if packet[1] == 5 and packet.size == 7:
      kind = 5
      status = packet[3]
      handle = io.LITTLE-ENDIAN.uint16 packet 4
      detail = packet[6]
    else if packet[1] == 0x3e and
        ((packet.size == 22 and packet[3] == 1) or (packet.size == 34 and packet[3] == 0x0a)):
      kind = packet[3]
      status = packet[4]
      handle = io.LITTLE-ENDIAN.uint16 packet 5
      detail = packet[7]
    else if packet[1] == 0x0e and packet.size >= 7:
      kind = 0x0e
      status = packet[6]
      handle = io.LITTLE-ENDIAN.uint16 packet 4
      detail = packet[3]
      if not (selected_ handle): return
    else if packet[1] == 0x0f and packet.size == 7:
      kind = 0x0f
      status = packet[3]
      handle = io.LITTLE-ENDIAN.uint16 packet 5
      detail = packet[4]
      if not (selected_ handle): return
    else:
      return
    append_ kind status handle detail

  append_ kind/int status/int handle/int detail/int -> none:
    offset := (count % 32) * 16
    records_[offset] = kind
    records_[offset + 1] = status
    io.LITTLE-ENDIAN.put-uint16 records_ offset + 2 handle
    records_[offset + 4] = detail
    io.LITTLE-ENDIAN.put-int64 records_ offset + 8 Time.monotonic-us
    count++

  // Call only after the controller receiver has ended.
  do-records [block] -> none:
    retained := min count 32
    retained.repeat: | i/int |
      sequence := count - retained + i
      offset := (sequence % 32) * 16
      block.call sequence records_[offset] records_[offset + 1]
          (io.LITTLE-ENDIAN.uint16 records_ offset + 2)
          records_[offset + 4]
          (io.LITTLE-ENDIAN.int64 records_ offset + 8)

  dump -> none:
    do-records: | sequence/int kind/int status/int handle/int detail/int us/int |
      print "CONNECTION_EVENT sequence=$sequence kind=$kind status=$status handle=$handle detail=$detail us=$us"
    print "CONNECTION_EVENTS total=$count retained=$(min count 32)"
