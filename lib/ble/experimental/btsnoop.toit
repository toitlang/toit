// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import io
import monitor

import .transport show Transport

/**
Records every packet crossing a $Transport in btsnoop format.

The output opens in Wireshark and btmon (data link 1002, HCI H4 with the
  packet-type byte). Records are written synchronously on the transport's own
  tasks; a slow writer slows the host. With payloads disabled only H4 headers are
  recorded, which keeps keys and application data out of the trace at the cost
  of readability. Close this transport, not the underlying one.
*/
class Btsnoop implements Transport:
  static FILE-HEADER_ ::= #['b', 't', 's', 'n', 'o', 'o', 'p', 0, 0, 0, 0, 1, 0, 0, 0x03, 0xea]
  // Microseconds from btsnoop's year-0 epoch to 1970-01-01.
  static EPOCH-OFFSET-US_ ::= 0x00dc_ddb3_0f2f_8000

  underlying_/Transport
  writer_/io.Writer
  payloads_/bool
  mutex_/monitor.Mutex ::= monitor.Mutex
  closed_/bool := false
  dropped_/int := 0

  constructor .underlying_ .writer_ --payloads/bool=true:
    payloads_ = payloads
    writer_.write FILE-HEADER_

  receive -> ByteArray:
    packet := underlying_.receive
    record_ packet --received
    return packet

  send packet/ByteArray -> none:
    underlying_.send packet
    record_ packet --no-received

  send-if packet/ByteArray [allowed] -> bool:
    sent := underlying_.send-if packet allowed
    if sent: record_ packet --no-received
    return sent

  close -> none:
    critical-do --no-respect-deadline:
      if closed_: return
      closed_ = true
      try:
        underlying_.close
      finally:
        if writer_ is io.CloseableWriter: catch: (writer_ as io.CloseableWriter).close

  record_ packet/ByteArray --received/bool -> none:
    if closed_ or packet.is-empty: return
    included := packet.size
    if not payloads_:
      included = min included (header-length_ packet)
    record := ByteArray 24
    io.BIG-ENDIAN.put-uint32 record 0 packet.size
    io.BIG-ENDIAN.put-uint32 record 4 included
    kind := packet[0]
    flags := (received ? 1 : 0) | ((kind == 1 or kind == 4) ? 2 : 0)
    io.BIG-ENDIAN.put-uint32 record 8 flags
    io.BIG-ENDIAN.put-uint32 record 12 dropped_
    io.BIG-ENDIAN.put-int64 record 16 (Time.now.ns-since-epoch / 1000 + EPOCH-OFFSET-US_)
    // Serialize writers: receive and send run on different tasks.
    error := catch:
      mutex_.do:
        if closed_: return
        writer_.write record
        writer_.write packet[..included]
    if error: dropped_++

  static header-length_ packet/ByteArray -> int:
    kind := packet[0]
    if kind == 1: return 4
    if kind == 2: return 5
    if kind == 4: return 3
    return 1
