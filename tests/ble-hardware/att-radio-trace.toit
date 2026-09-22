// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.transport
import io

/** Records bounded ACL routing metadata without retaining attribute values. */
class Trace implements transport.Transport:
  underlying_/transport.Transport
  limit_/int
  records_/int := 0
  closed_/bool := false

  constructor .underlying_ --limit/int=512:
    if not 1 <= limit <= 10_000: throw "INVALID_ARGUMENT"
    limit_ = limit

  receive -> ByteArray:
    packet := underlying_.receive
    record_ "RX" packet
    return packet

  send packet/ByteArray -> none:
    underlying_.send packet
    record_ "TX" packet

  send-if packet/ByteArray [allowed] -> bool:
    sent := underlying_.send-if packet allowed
    if sent: record_ "TX" packet
    return sent

  close -> none:
    if closed_: return
    closed_ = true
    underlying_.close
    print "ATT_RADIO_TRACE COMPLETE records=$records_"

  record_ direction/string packet/ByteArray -> none:
    if records_ == limit_ or packet.size < 5 or packet[0] != 2: return
    records_++
    handle-flags := io.LITTLE-ENDIAN.uint16 packet 1
    handle := handle-flags & 0x0fff
    boundary := handle-flags >> 12 & 3
    acl-length := io.LITTLE-ENDIAN.uint16 packet 3
    if boundary == 2 and packet.size >= 10:
      channel := io.LITTLE-ENDIAN.uint16 packet 7
      first := packet[9]
      print "ATT_RADIO_TRACE $direction record=$records_ handle=$handle boundary=$boundary acl-length=$acl-length channel=$channel first=$first us=$(Time.monotonic-us)"
    else:
      print "ATT_RADIO_TRACE $direction record=$records_ handle=$handle boundary=$boundary acl-length=$acl-length channel=-1 first=-1 us=$(Time.monotonic-us)"
