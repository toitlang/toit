// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.
import ble.experimental.central
import ble.experimental.esp32
import ble.experimental.hci
import ble.experimental.signaling
import ble.experimental.transport
import encoding.hex
import system

class CountingTransport implements transport.Transport:
  radio_ ::= esp32.Esp32Transport
  updates/int := 0
  receive -> ByteArray: return radio_.receive
  close -> none: radio_.close
  send packet/ByteArray -> none:
    radio_.send packet
    count_ packet
  send-if packet/ByteArray [allowed] -> bool:
    sent := radio_.send-if packet allowed
    if sent: count_ packet
    return sent
  count_ packet/ByteArray:
    if packet.size >= 4 and packet[0] == 1 and packet[1] == 0x13 and packet[2] == 0x20:
      updates++

main arguments/List:
  if arguments.size != 1: throw "EXPECTED_PUBLIC_PEER_HEX_ADDRESS"
  run (hex.decode arguments[0]).reverse

/** Runs the optional radio fixture against a public peer in HCI byte order. */
run peer-address/ByteArray:
  radio := CountingTransport
  controller := hci.Controller radio
  host/central.Central? := null
  retained := []
  before := system.process-stats --gc
  try:
    info := hci.initialize controller
    host = central.Central controller --acl-length=info.acl-length --acl-count=info.acl-count
        --accept-parameter-requests
    link := host.connect peer-address --address-type=0
        --timeout=(Duration --s=20)
    print "PARAM_RETRY CONNECTED"
    6.repeat: | round/int |
      with-timeout --ms=35_000:
        expected := round < 2
            ? signaling.parameter-request 7
            : round < 4
                ? #[0x12, 8, 8, 0, 12, 0, 12, 0, 0, 2, 0x90, 1]
                : signaling.parameter-request 9 --interval=40
        packet := link.receive
        if packet.channel != 5 or packet.payload != expected: throw "UNEXPECTED_REQUEST"
        host.handle-signaling link packet.payload
        while link.peer-parameters-pending:
          sleep --ms=1
        if link.peer-parameter-error: throw link.peer-parameter-error
        expected-count := round < 4 ? 1 : 2
        expected-interval := round < 4 ? 12 : 40
        if radio.updates != expected-count or link.parameters.interval != expected-interval:
          throw "UNEXPECTED_CONTROLLER_UPDATES"
        system.process-stats --gc
        host.send link 4 #[0x0a, 3, 0]
        response := link.receive
        if response.channel != 4 or response.payload != #[0x0b, 42, round]:
          throw "ATT_MISMATCH"
        retained.add response.payload
        print "PARAM_RETRY ROUND round=$round updates=$radio.updates interval=$expected-interval"
    system.process-stats --gc
    retained.size.repeat: | index/int |
      if retained[index] != #[0x0b, 42, index]: throw "RETAINED_BYTES_CHANGED"
    host.disconnect link
  finally:
    if host:
      host.close
      host.wait-closed
    else:
      controller.close
      controller.wait-closed
  after := system.process-stats --gc
  gcs := after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT]
  if gcs < 6: throw "GC_NOT_OBSERVED"
  print "PARAM_RETRY COMPLETE updates=$radio.updates reads=6 retained=6 full-gcs=$gcs"
