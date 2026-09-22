// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.esp32
import ble.experimental.transport
import .fixtures.hci-server as fixture

main:
  fixture.run Radio --no-dynamic --report-address --cycles=2

class Radio implements transport.Transport:
  inner_/transport.Transport ::= esp32.Esp32Transport
  send packet/ByteArray -> none: inner_.send packet
  send-if packet/ByteArray [allowed] -> bool:
    return inner_.send-if packet: allowed.call
  receive -> ByteArray:
    packet := inner_.receive
    // Record only link lifecycle events, never security keys or application data.
    if packet.size >= 4 and packet[0] == 4 and
        (packet[1] == 5 or (packet[1] == 0x3e and (packet[3] == 1 or packet[3] == 0x0a))):
      print "MIXED_PROVIDER_DEATH PEER_LINK_EVENT $packet"
    return packet
  close -> none: inner_.close
