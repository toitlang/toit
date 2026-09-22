// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.central
import ble.experimental.esp32
import ble.experimental.hci
import ble.experimental.transport
import io
import system
import .hci-echo as fixture
import .vhci-receive-setup as setup

// Fixture-only ATT-shaped payloads over the fixed channel; no GATT database.
START ::= #[0x52, 1, 0, 0xa0]
DONE ::= #[0x52, 1, 0, 0xa1]
ACK ::= #[0x52, 1, 0, 0xa2]

main: run --receiver --peer-address=#[0x3a, 0x0b, 0xa0, 3, 0xf7, 0x84]

run --receiver/bool --peer-address/ByteArray --flow-control/bool=true:
  radio := CountedRadio (esp32.Esp32Transport)
  controller := hci.Controller radio
  host/central.Central? := null
  try:
    info := hci.initialize controller
    if receiver and flow-control:
      if info.commands[10] & 0xe0 != 0xe0: throw "RX_FLOW_COMMANDS_UNSUPPORTED"
      setup.configure controller 0 0x0c33 #[0, 4, 0, 4, 0, 0, 0]
      setup.configure controller 0 0x0c31 #[1]
    host = central.Central controller --acl-length=info.acl-length --acl-count=info.acl-count
    print "RX_WINDOW READY receiver=$receiver flow-control=$(receiver and flow-control)"
    link := receiver
        ? (host.connect peer-address --address-type=0)
        : (host.accept (#[2, 1, 6, 17, 7] + (fixture.wire-uuid "9f6c6500-8e2a-4b13-9e97-94f353eeb001")))
    if link.info.address-type != 0 or link.info.address != peer-address:
      throw "RX_WINDOW_UNEXPECTED_PEER"
    with-timeout --ms=10_000:
      if receiver:
        receive-window host link controller radio info.address
      else:
        require-payload link START
        8.repeat: | sequence/int | host.send link 4 (numbered sequence)
        print "RX_WINDOW_SENDER SUBMITTED count=8"
        require-payload link DONE
        host.send link 4 ACK
        with-timeout --ms=3_000: link.wait-disconnected
        print "RX_WINDOW_SENDER COMPLETE submitted=8 acknowledged=8"
  finally:
    if host:
      host.close
      host.wait-closed
    else:
      controller.close
      controller.wait-closed

receive-window host/central.Central link/central.Link controller/hci.Controller
    radio/CountedRadio address/ByteArray:
  host.send link 4 START
  retained := []
  4.repeat: | sequence/int | retained.add (require-payload link (numbered sequence))
  paused controller radio address retained 4
  radio.complete link 1
  retained.add (require-payload link (numbered 4))
  paused controller radio address retained 5
  // Four buffers are outstanding again; release them to admit the final three.
  radio.complete link 4
  3.repeat: | index/int | retained.add (require-payload link (numbered (index + 5)))
  if radio.received != 8: throw "RX_WINDOW_UNEXPECTED_PACKET_COUNT"
  radio.complete link 3
  host.send link 4 DONE
  require-payload link ACK
  if radio.received != 9: throw "RX_WINDOW_UNEXPECTED_PACKET_COUNT"
  radio.complete link 1
  host.disconnect link
  print "RX_WINDOW_RECEIVER COMPLETE exact=8 acl-received=$(radio.received) credits-returned=$(radio.returned)"

paused controller/hci.Controller radio/CountedRadio address/ByteArray retained/List expected/int:
  before := system.process-stats
  3.repeat: system.process-stats --gc
  sleep --ms=250
  // HCI command responses must still progress while ACL receive credits are zero.
  if (controller.command hci.READ-ADDRESS) != address: throw "RX_WINDOW_ADDRESS_CHANGED"
  if radio.received != expected:
    throw "RX_WINDOW_CREDIT_LIMIT_EXCEEDED received=$(radio.received) expected=$expected"
  retained.size.repeat: | sequence/int |
    if retained[sequence] != (numbered sequence): throw "RX_WINDOW_RETAINED_DATA_CHANGED"
  after := system.process-stats
  gcs := after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT]
  if gcs < 3: throw "RX_WINDOW_EXPECTED_GC"
  print "RX_WINDOW PAUSED received=$expected returned=$(radio.returned) full-gcs=$gcs control-responsive=true"

require-payload link/central.Link expected/ByteArray -> ByteArray:
  packet := link.receive
  if packet.channel != 4 or packet.payload != expected: throw "RX_WINDOW_PAYLOAD_MISMATCH"
  return packet.payload

numbered sequence/int -> ByteArray: return #[0x52, 1, 0] + (fixture.payload sequence)

// This wrapper never automatically returns credits. The fixture owns one link
// and deliberately acknowledges only explicitly consumed packets before close.
class CountedRadio implements transport.Transport:
  radio_/transport.Transport
  received/int := 0
  returned/int := 0
  handle_/int? := null

  constructor .radio_:

  receive -> ByteArray:
    packet := radio_.receive
    if packet[0] == 2:
      handle := (io.LITTLE-ENDIAN.uint16 packet 1) & 0x0fff
      if handle_ != null and handle_ != handle: throw "RX_WINDOW_MULTIPLE_HANDLES"
      handle_ = handle
      received++
    return packet

  send packet/ByteArray -> none: radio_.send packet
  send-if packet/ByteArray [allowed] -> bool: return radio_.send-if packet allowed
  close -> none: radio_.close

  complete link/central.Link count/int -> none:
    if not link.connected or link.info.handle != handle_ or not 1 <= count <= received - returned:
      throw "RX_WINDOW_INVALID_COMPLETION"
    parameters := #[1, 0, 0, 0, 0]
    io.LITTLE-ENDIAN.put-uint16 parameters 1 link.info.handle
    io.LITTLE-ENDIAN.put-uint16 parameters 3 count
    // Core Vol 4 Part E 7.3.40: no ordinary command credits or success event.
    with-timeout --ms=1_000: radio_.send (hci.command-packet 0x0c35 parameters)
    returned += count
