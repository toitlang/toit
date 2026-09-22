// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.att
import ble.experimental.attribute-server as attributes
import ble.experimental.bounded-central as bounded
import ble.experimental.gatt-server as gatt
import ble.experimental.hci
import ble.experimental.linux
import ble.experimental.transport
import encoding.hex
import monitor
import system

main args/List:
  if not 2 <= args.size <= 3: throw "Usage: bounded-radio.toit <adapter index> <public survivor address> [winning]"
  winning := args.size == 3
  if winning and args[2] != "winning": throw "INVALID_ARGUMENT"
  peer := (hex.decode (args[1].replace --all ":" "")).reverse
  run (linux.LinuxTransport (int.parse args[0])) peer --winning=winning

run underlying/transport.Transport peer/ByteArray --winning/bool=false:
  radio := ObservedTransport underlying --hold-win=winning
  controller := hci.Controller radio
  host/bounded.Central? := null
  client/att.Client? := null
  caller/Task? := null
  try:
    info := hci.initialize controller
    bounded.configure controller info
    host = bounded.Central controller --acl-length=info.acl-length --acl-count=info.acl-count
        --link-limit=2
        --early-acl-timeout=(Duration --ms=20)
    link := host.connect peer --address-type=0 --timeout=(Duration --s=20)
    client = att.Client host link
    read-values client
    ended := monitor.Latch
    returned := false
    caller = task::
      try:
        error := catch:
          host.accept #[2, 1, 6] --timeout=(Duration --s=60)
          returned = true
        if error and not radio.first-enabled.has-value:
          radio.first-enabled.set error --exception
        if error and not radio.winning-completion.has-value:
          radio.winning-completion.set error --exception
      finally:
        critical-do --no-respect-deadline: ended.set true
    with-timeout --ms=5_000: radio.first-enabled.get
    if winning:
      print "BOUNDED_RADIO WIN_READY address=$(hex.encode info.address.reverse)"
      with-timeout --ms=40_000: radio.winning-completion.get
    else if radio.terminated != 0:
      throw "WINDOW_ALREADY_TERMINATED"
    prior-terminations := radio.terminated
    start := Time.monotonic-us
    caller.cancel
    if winning:
      yield
      if ended.has-value: throw "WINNING_ACCEPT_ENDED_BEFORE_DELIVERY"
      radio.release-winning.set true
    with-timeout --ms=4_000: ended.get
    if returned or radio.terminated != prior-terminations + 1 or radio.last-status != (winning ? 0 : 0x3c):
      throw "BOUNDED_CANCEL_RESULT"
    cleanup-us := Time.monotonic-us - start
    if not link.connected: throw "BOUNDED_SURVIVOR_LOST"
    read-values client
    print "BOUNDED_RADIO CANCELED winning=$winning cleanup-us=$cleanup-us survivor-reads=200"
    print "BOUNDED_RADIO ACCEPT_READY address=$(hex.encode info.address.reverse)"
    database := attributes.Database.with-defaults --name="Toit HCI"
    2.repeat: | cycle/int |
      incoming := host.accept #[2, 1, 6] --timeout=(Duration --s=60)
      server := gatt.Server host incoming database
      served := monitor.Latch
      worker := task::
        try:
          error := catch:
            server.serve: | handle/int value/ByteArray | throw "UNEXPECTED_WRITE"
          served.set (error or true) --exception=(error != null)
        finally:
          critical-do --no-respect-deadline:
            if not served.has-value: served.set "SERVER_ABORTED" --exception
      try:
        read-values client
        with-timeout --ms=20_000: served.get
      finally:
        worker.cancel
        server.close
      if not link.connected: throw "BOUNDED_SURVIVOR_LOST"
      read-values client
      print "BOUNDED_RADIO CYCLE cycle=$cycle peer-handle=$(incoming.info.handle) survivor-reads=$((cycle + 1) * 200 + 200)"
    if radio.read-requests != 200: throw "BOUNDED_PEER_READ_COUNT"
    host.disconnect link
    link.wait-disconnected
    print "BOUNDED_RADIO COMPLETE survivor-reads=600 peer-reads=$(radio.read-requests) terminations=$(radio.terminated)"
  finally:
    if caller: caller.cancel
    if client: client.close
    if host:
      host.close
      host.wait-closed
    else:
      controller.close
      controller.wait-closed
    print "BOUNDED_RADIO COMMAND_ERRORS $(radio.command-errors)"
    print "BOUNDED_RADIO ENABLE_REPLY $(radio.enabled-reply)"
    if winning and radio.winning-completion.has-value:
      event := null
      error := catch: event = radio.winning-completion.get
      if not error: print "BOUNDED_RADIO WINNING_EVENT $event"

read-values client/att.Client:
  retained/ByteArray? := null
  before := system.process-stats
  100.repeat: | index/int |
    value := client.read 3
    if value != "Toit HCI".to-byte-array: throw "BOUNDED_VALUE_MISMATCH"
    if index == 0: retained = value
    if index % 10 == 0: system.process-stats --gc
  if retained != "Toit HCI".to-byte-array: throw "BOUNDED_RETAINED_VALUE_CHANGED"
  after := system.process-stats
  if after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT] < 10:
    throw "BOUNDED_GC_COUNT"

class ObservedTransport implements transport.Transport:
  underlying_/transport.Transport
  first-enabled/monitor.Latch ::= monitor.Latch
  terminated/int := 0
  last-status/int := -1
  read-requests/int := 0
  command-errors/List := []
  enabled-reply/ByteArray? := null
  hold-win_/bool
  winning-completion/monitor.Latch ::= monitor.Latch
  release-winning/monitor.Latch ::= monitor.Latch

  constructor .underlying_ --hold-win/bool=false:
    hold-win_ = hold-win

  receive -> ByteArray:
    packet := underlying_.receive
    if packet.size >= 7 and packet[0] == 4:
      if packet[1] == 14 and packet[6] != 0 and command-errors.size < 16:
        command-errors.add [packet[4] | packet[5] << 8, packet[6]]
      if packet[1] == 15 and packet[3] != 0 and command-errors.size < 16:
        command-errors.add [packet[5] | packet[6] << 8, packet[3]]
    if packet.size == 7 and packet[..3] == #[4, 14, 4] and
        packet[4..] == #[0x39, 0x20, 0] and not first-enabled.has-value:
      enabled-reply = packet.copy
      first-enabled.set true
    if packet.size == 9 and packet[..4] == #[4, 0x3e, 6, 0x12]:
      terminated++
      last-status = packet[4]
    if hold-win_ and not winning-completion.has-value and packet.size == 34 and
        packet[..5] == #[4, 0x3e, 31, 0x0a, 0] and packet[7] == 1:
      winning-completion.set packet.copy
      release-winning.get
    // Read handle3 fits one ACL packet at the negotiated default MTU. No value
    // logging, extra receive task or retained packet callback is needed.
    if packet.size == 12 and packet[0] == 2 and packet[2] & 0x30 != 0x10 and
        packet[5..] == #[3, 0, 4, 0, 0x0a, 3, 0]:
      read-requests++
    return packet

  send packet/ByteArray -> none: underlying_.send packet
  send-if packet/ByteArray [allowed] -> bool: return underlying_.send-if packet allowed
  close -> none:
    release-winning.set true
    underlying_.close
