// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.advertising-updates as updates
import ble.experimental.attribute-server as attributes
import ble.experimental.central as central
import ble.experimental.esp32 as esp32
import ble.experimental.gatt-server as gatt
import ble.experimental.hci as hci
import ble.experimental.transport as transport
import monitor
import system

main:
  with-timeout --ms=90_000:
    before := system.process-stats
    2.repeat: | stage/int |
      interrupted stage
      sleep --ms=3_000
    recovered
    after := system.process-stats
    gcs := after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT]
    if gcs < 24: throw "ACCEPT_CANCEL_GC_MISSING"
    print "ACCEPT_CANCEL COMPLETE stages=2 recovery-reads=20 retained=4 full-gcs=$gcs"

interrupted stage/int:
  radio := Radio stage
  controller := hci.Controller radio
  host/central.Central? := null
  accepter/Task? := null
  updater/Task? := null
  accepted := monitor.Latch
  updated := monitor.Latch
  changes := updates.Changes
  try:
    info := hci.initialize controller --receive-acl-packets=4
    host = central.Central controller --acl-length=info.acl-length --acl-count=info.acl-count
    data := payload stage 0
    response := scan-response stage 0
    print "ACCEPT_CANCEL ADVERTISING stage=$stage"
    accepter = task::
      result := null
      error := null
      try:
        error = catch: result = host.accept data --scan-response=response --updates=changes
      finally:
        critical-do --no-respect-deadline: accepted.set [result, error]
    radio.enabled.get
    data.fill 0
    response.fill 0
    system.process-stats --gc
    sleep --ms=4_000
    data = payload stage 1
    response = scan-response stage 1
    updater = task::
      result := null
      error := null
      try:
        error = catch: result = changes.update data response
      finally:
        critical-do --no-respect-deadline: updated.set [result, error]
    radio.held.get
    data.fill 0
    response.fill 0
    system.process-stats --gc
    // Observe repeated radio reports while the real successful reply is held,
    // staying below the ordinary three-second HCI command deadline.
    sleep --ms=1_500
    accepter.cancel
    radio.release.set true
    if accepted.get != [null, null]: throw "ACCEPT_CANCEL_ACCEPT_RETURNED"
    if updated.get != [false, null]: throw "ACCEPT_CANCEL_UPDATE_RETURNED"
  finally:
    radio.release.set true
    if host:
      host.close
      host.wait-closed
    else:
      controller.close
      controller.wait-closed
    if accepter: accepter.cancel
    if updater: updater.cancel
  if radio.closes != 1 or radio.enables != 1 or radio.disables != 0 or
      radio.data-count != 2 or radio.response-count != stage + 1:
    throw "ACCEPT_CANCEL_COMMAND_COUNTS"
  print "ACCEPT_CANCEL STOPPED stage=$stage closes=1 enables=1 disables=0 data=2 response=$(stage + 1)"

recovered:
  radio := Radio 2
  controller := hci.Controller radio
  host/central.Central? := null
  count := 0
  retained := []
  database := attributes.Database
  database.add-service #[0xf0, 0xff]
  value := database.add-characteristic #[0xf1, 0xff] --read --dynamic-read
  try:
    info := hci.initialize controller --receive-acl-packets=4
    host = central.Central controller --acl-length=info.acl-length --acl-count=info.acl-count
    print "ACCEPT_CANCEL RECOVERY"
    link := host.accept (payload 2 0) --scan-response=(scan-response 2 0)
    if link.info.address != #[0xa9, 0x56, 0xa3, 0x4b, 0x88, 0x8a] or link.info.address-type != 0:
      throw "ACCEPT_CANCEL_WRONG_PEER"
    server := gatt.Server host link database
    server.serve-with-reads
        (: | request/attributes.ReadRequest |
          if request.handle != value or count >= 20: throw "ACCEPT_CANCEL_UNEXPECTED_READ"
          bytes := #[count++, 42]
          if retained.size < 4: retained.add bytes
          system.process-stats --gc
          retained.size.repeat:
            if retained[it] != #[it, 42]: throw "ACCEPT_CANCEL_RETAINED_CHANGED"
          request.reply bytes)
        (: | _ _ | unreachable)
    if count != 20: throw "ACCEPT_CANCEL_RECOVERY_INCOMPLETE"
  finally:
    if host:
      host.close
      host.wait-closed
    else:
      controller.close
      controller.wait-closed
  if radio.closes != 1 or radio.enables != 1 or radio.disables != 1 or
      radio.data-count != 1 or radio.response-count != 1:
    throw "ACCEPT_CANCEL_RECOVERY_COUNTS"
  print "ACCEPT_CANCEL RECOVERED reads=20 closes=1 enables=1 disables=1 data=1 response=1"

payload stage/int phase/int -> ByteArray:
  bytes := ByteArray 31 --initial=(0x30 + phase)
  bytes.replace 0 #[2, 1, 6, 27, 0xff, 0xff, 0xff, 'a', 'c', 'c', stage, phase]
  return bytes

scan-response stage/int phase/int -> ByteArray:
  bytes := ByteArray 31 --initial=(0x41 + phase)
  bytes.replace 0 #[30, 9, 'a', 'c', 'c', '0' + stage, '0' + phase]
  return bytes

class Radio implements transport.Transport:
  stage_/int
  radio_/esp32.Esp32Transport ::= esp32.Esp32Transport
  enabled/monitor.Latch ::= monitor.Latch
  held/monitor.Latch ::= monitor.Latch
  release/monitor.Latch ::= monitor.Latch
  data-count/int := 0
  response-count/int := 0
  enables/int := 0
  disables/int := 0
  closes/int := 0
  replies_/int := 0
  constructor .stage_:

  receive -> ByteArray:
    packet := radio_.receive
    if packet.size == 7 and packet[0] == 4 and packet[1] == 14 and packet[5] == 32:
      if packet[4] == 10 and packet[6] == 0: enabled.set true
      if stage_ < 2 and packet[4] == 8 + stage_:
        replies_++
        if replies_ == 2:
          if packet[6] != 0: throw "ACCEPT_CANCEL_COMMAND_REJECTED"
          print "ACCEPT_CANCEL HELD stage=$stage_ opcode=$(0x2008 + stage_) status=0"
          held.set true
          release.get
    return packet

  send packet/ByteArray -> none:
    send-if packet: true

  send-if packet/ByteArray [allowed] -> bool:
    if not (radio_.send-if packet allowed): return false
    if packet.size >= 5 and packet[0] == 1 and packet[2] == 32:
      if packet[1] == 8: data-count++
      if packet[1] == 9: response-count++
      if packet[1] == 10:
        if packet[4] == 1: enables++
        else: disables++
    return true

  close -> none:
    if closes != 0: return
    closes++
    release.set true
    radio_.close
