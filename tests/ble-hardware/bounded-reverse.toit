// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.att
import ble.experimental.attribute-server as attributes
import ble.experimental.bounded-central as bounded
import ble.experimental.central
import ble.experimental.controller-states as states
import ble.experimental.gatt-server as gatt
import ble.experimental.hci
import ble.experimental.linux
import ble.experimental.transport
import encoding.hex
import monitor
import .bounded-radio as fixture

CONTROL-HANDLE ::= 12

main args/List:
  if args.size != 2: throw "Usage: bounded-reverse.toit <adapter index> <public outgoing peer address>"
  peer := (hex.decode (args[1].replace --all ":" "")).reverse
  run (linux.LinuxTransport (int.parse args[0])) peer

run underlying/transport.Transport peer/ByteArray:
  radio := fixture.ObservedTransport underlying
  controller := hci.Controller radio
  host/bounded.Central? := null
  server/gatt.Server? := null
  worker/Task? := null
  try:
    info := hci.initialize controller
    supported := states.read controller
    print "BOUNDED_REVERSE STATES $(hex.encode supported.bytes)"
    bounded.configure controller info
    host = bounded.Central controller --acl-length=info.acl-length --acl-count=info.acl-count
        --link-limit=2
        --early-acl-timeout=(Duration --ms=20)
    database := attributes.Database.with-defaults --name="Toit HCI"
    database.add-service #[0xf0, 0xff]
    control := database.add-characteristic #[0xf1, 0xff] --read --write --value=#[0]
    if control != CONTROL-HANDLE: throw "REVERSE_FIXTURE_LAYOUT_CHANGED"
    print "BOUNDED_REVERSE ACCEPT_READY address=$(hex.encode info.address.reverse)"
    incoming := host.accept #[2, 1, 6] --timeout=(Duration --s=60)
    server = gatt.Server host incoming database
    completed := monitor.Latch
    acknowledged := [monitor.Latch, monitor.Latch]
    phase := 0
    worker = task::
      try:
        error := catch:
          server.serve: | handle/int value/ByteArray |
            if handle != control or phase == 0 or value != #[phase]:
              throw "REVERSE_UNEXPECTED_ACK"
            ack/monitor.Latch := acknowledged[phase - 1]
            if ack.has-value: throw "REVERSE_DUPLICATE_ACK"
            ack.set true
        completed.set (error or true) --exception=(error != null)
      finally:
        critical-do --no-respect-deadline:
          if not completed.has-value: completed.set "REVERSE_SERVER_ABORTED" --exception
    print "BOUNDED_REVERSE PERIPHERAL_FIRST handle=$(incoming.info.handle)"
    previous/central.Link? := null
    2.repeat: | cycle/int |
      outgoing := host.connect peer --address-type=0 --timeout=(Duration --s=20)
      client := att.Client host outgoing
      try:
        if not incoming.connected: throw "REVERSE_SURVIVOR_LOST"
        fixture.read-values client
        host.disconnect outgoing
        outgoing.wait-disconnected
      finally:
        client.close
      if not incoming.connected: throw "REVERSE_SURVIVOR_LOST"
      if previous and (previous.connected or not previous.has-ended):
        throw "REVERSE_OLD_LINK_REUSED"
      previous = outgoing
      // Publish only after physical disconnection. The peer acknowledges after
      // another hundred exact reads on its surviving peripheral-role link.
      phase = cycle + 1
      database.set-value control #[phase]
      with-timeout --ms=20_000: (acknowledged[cycle] as monitor.Latch).get
      print "BOUNDED_REVERSE CYCLE cycle=$cycle outgoing-handle=$(outgoing.info.handle) survivor-reads=$((cycle + 1) * 200)"
    with-timeout --ms=5_000: completed.get
    if radio.read-requests != 400: throw "REVERSE_SURVIVOR_READ_COUNT"
    print "BOUNDED_REVERSE COMPLETE outgoing-reads=200 survivor-reads=$(radio.read-requests)"
  finally:
    if worker: worker.cancel
    if server: server.close
    if host:
      host.close
      host.wait-closed
    else:
      controller.close
      controller.wait-closed
    print "BOUNDED_REVERSE COMMAND_ERRORS $(radio.command-errors)"
