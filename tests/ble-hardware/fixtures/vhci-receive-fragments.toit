// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.acl
import ble.experimental.central
import ble.experimental.esp32
import ble.experimental.hci
import io
import system
import .vhci-receive-window as window
import .vhci-receive-setup as setup

main: run --receiver --peer-address=#[0x3a, 0x0b, 0xa0, 3, 0xf7, 0x84]

run --receiver/bool --peer-address/ByteArray:
  radio := FragmentRadio
  controller := hci.Controller radio
  host/central.Central? := null
  try:
    info := hci.initialize controller
    if receiver:
      setup.configure controller 0 0x0c33 #[0, 4, 0, 1, 0, 0, 0]
      setup.configure controller 0 0x0c31 #[1]
    // Force the transmitter to submit fragments smaller than this PDU. The
    // receiver checks actual HCI fragmentation rather than assuming preservation.
    host = central.Central controller --acl-length=27 --acl-count=info.acl-count --receive-limit=1024
    print "RX_FRAGMENTS READY receiver=$receiver"
    link := receiver
        ? (host.connect peer-address --address-type=0)
        : (host.accept #[2, 1, 6])
    if link.info.address-type != 0 or link.info.address != peer-address:
      throw "RX_FRAGMENTS_UNEXPECTED_PEER"
    with-timeout --ms=10_000:
      if receiver:
        receive-fragments host link controller radio info.address
      else:
        window.require-payload link window.START
        host.send link 4 payload
        print "RX_FRAGMENTS_SENDER SUBMITTED bytes=512"
        window.require-payload link window.DONE
        host.send link 4 window.ACK
        with-timeout --ms=3_000: link.wait-disconnected
        print "RX_FRAGMENTS_SENDER COMPLETE acknowledged=512"
  finally:
    if host:
      host.close
      host.wait-closed
    else:
      controller.close
      controller.wait-closed

receive-fragments host/central.Central link/central.Link controller/hci.Controller
    radio/FragmentRadio address/ByteArray:
  before := system.process-stats
  host.send link 4 window.START
  fragments := 0
  while true:
    radio.progress.wait (fragments + 1)
    fragments++
    if radio.received != fragments: throw "RX_FRAGMENTS_WINDOW_EXCEEDED"
    if fragments == 1:
      if radio.assembled != null: throw "RX_FRAGMENTS_EXPECTED_FRAGMENTATION"
      3.repeat: system.process-stats --gc
      sleep --ms=250
      if (controller.command hci.READ-ADDRESS) != address: throw "RX_FRAGMENTS_ADDRESS_CHANGED"
      if radio.received != 1: throw "RX_FRAGMENTS_WINDOW_EXCEEDED"
      print "RX_FRAGMENTS PAUSED received=1 assembled=false control-responsive=true"
    system.process-stats --gc
    complete := radio.assembled != null
    // Partial data already has bounded managed storage; do not wait for the
    // entire PDU before releasing this fragment's receive capacity.
    radio.complete link 1
    if complete: break
  retained := window.require-payload link payload
  if fragments <= 1 or radio.assembled != retained: throw "RX_FRAGMENTS_REASSEMBLY_MISMATCH"
  system.process-stats --gc
  if retained != payload: throw "RX_FRAGMENTS_RETAINED_DATA_CHANGED"
  after := system.process-stats
  gcs := after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT]
  compacting := after[system.STATS-INDEX-FULL-COMPACTING-GC-COUNT] - before[system.STATS-INDEX-FULL-COMPACTING-GC-COUNT]
  if gcs < fragments + 4: throw "RX_FRAGMENTS_EXPECTED_GC"
  host.send link 4 window.DONE
  window.require-payload link window.ACK
  if radio.received != fragments + 1: throw "RX_FRAGMENTS_UNEXPECTED_PACKET_COUNT"
  radio.complete link 1
  host.disconnect link
  print "RX_FRAGMENTS_RECEIVER COMPLETE bytes=512 fragments=$fragments received=$(radio.received) returned=$(radio.returned) full-gcs=$gcs compacting-gcs=$compacting"

payload -> ByteArray: return ByteArray 512: it % 251

monitor Progress:
  count_/int := 0
  advance count/int -> none: count_ = count
  wait count/int -> none: await: count_ >= count

class FragmentRadio extends window.CountedRadio:
  progress/Progress ::= Progress
  assembled/ByteArray? := null
  reassembler_/acl.Reassembler? := null

  constructor:
    super (esp32.Esp32Transport)

  receive -> ByteArray:
    packet := super
    if packet[0] == 2:
      if not reassembler_:
        reassembler_ = acl.Reassembler ((io.LITTLE-ENDIAN.uint16 packet 1) & 0x0fff) --limit=1024
      pdu := reassembler_.accept packet
      if pdu: assembled = pdu.payload
      progress.advance received
    return packet
