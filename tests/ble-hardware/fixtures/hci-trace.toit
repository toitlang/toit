// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.transport as transport
import encoding.hex

/** Stores the first 64 HCI headers, excluding payloads that may contain keys or SMP data. */
class Trace implements transport.Transport:
  underlying_/transport.Transport
  entries_/List := []
  closed_/bool := false

  constructor .underlying_:

  receive -> ByteArray:
    packet := underlying_.receive
    record_ "RX" packet
    return packet

  send packet/ByteArray -> none:
    record_ "TX" packet
    underlying_.send packet

  send-if packet/ByteArray [allowed] -> bool:
    sent := underlying_.send-if packet allowed
    if sent: record_ "TX" packet
    return sent

  close -> none:
    if closed_: return
    closed_ = true
    underlying_.close
    entries_.do: | entry/List |
      print "HCI_TRACE $(entry[0]) us=$(entry[1]) header=$(hex.encode entry[2]) payload=omitted"
    entries_.clear

  record_ direction/string packet/ByteArray -> none:
    if entries_.size == 64 or closed_: return
    entries_.add [direction, Time.monotonic-us, (trace-header packet)]

/** Copies only H4 framing; command, event, and ACL payloads are never retained. */
trace-header packet/ByteArray -> ByteArray:
  if packet.is-empty: return #[]
  length := packet[0] == 1 ? 4 : (packet[0] == 2 ? 5 : (packet[0] == 4 ? 3 : 1))
  return packet[..min length packet.size].copy
