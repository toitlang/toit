// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.attribute-server as attributes
import ble.experimental.central
import ble.experimental.hci
import ble.experimental.linux
import ble.experimental.signaling
import io
import .hci-echo as fixture

// Controlled peer fixture, not a live-mutation API for the production server.
main args/List:
  if args.size != 1: throw "Usage: hci-cache-migration.toit <adapter>"
  controller := hci.Controller (linux.LinuxTransport (int.parse args[0]))
  host/central.Central? := null
  session/attributes.Session? := null
  try:
    info := hci.initialize controller
    if info.address != #[0xc2, 0xda, 0x2a, 0xac, 0xbe, 8]: throw "WRONG_CONTROLLER"
    host = central.Central controller --acl-length=info.acl-length --acl-count=info.acl-count
        --early-acl-timeout=(Duration --ms=20)
    uuid := fixture.wire-uuid "9f6c4300-8e2a-4b13-9e97-94f353eeb001"
    database := attributes.Database.with-defaults
    changed/int := database.service-changed-handle
    database.add-service uuid
    original := database.add-characteristic #[0xf1, 0xff] --read --write --value=#[7]
    replacement := attributes.Database.with-defaults
    replacement.add-service uuid
    decoy := replacement.add-characteristic #[0xf2, 0xff] --read --write --value=#[99]
    moved := replacement.add-characteristic #[0xf1, 0xff] --read --write --value=#[8]
    if original != decoy or moved == original: throw "INVALID_FIXTURE_LAYOUT"
    session = database.session
    print "CACHE_MIGRATION_PEER READY"
    link := host.accept (#[2, 1, 6, 17, 7] + uuid) --timeout=(Duration --s=60)
    if link.info.address != #[1, 0x30, 0x23, 0xf2, 0x3a, 0xc8] or link.info.address-type != 1:
      throw "WRONG_FIXTURE_PEER"
    reads := 0
    writes := 0
    migrated := false
    confirmed := false
    error := catch:
      with-timeout --ms=30_000:
        while true:
          packet := link.receive
          if packet.channel == 5:
            host.handle-signaling link packet.payload
            continue
          if packet.channel == 6:
            response := signaling.security-response packet.payload
            if response: host.send link 6 response
            continue
          if packet.channel != 4: throw "UNEXPECTED_CHANNEL"
          request := packet.payload
          if request == #[0x1e]:
            if not migrated or confirmed: throw "UNEXPECTED_CONFIRMATION"
            confirmed = true
            continue
          if request.size >= 3 and (request[0] == 0x0a or request[0] == 0x12):
            handle := io.LITTLE-ENDIAN.uint16 request 1
            if migrated and handle == decoy: throw "STALE_HANDLE_USED"
            if handle == (migrated ? moved : original):
              if request[0] == 0x0a: reads++
              else: writes++
          response := session.request request
          if reads == 2 and not migrated:
            indication := session.indication changed
            if not indication: throw "MONITOR_NOT_SUBSCRIBED"
            session.close
            session = replacement.session
            // This fixture keeps the default GATT service at the same handles.
            enable := #[0x12, 0, 0, 2, 0]
            io.LITTLE-ENDIAN.put-uint16 enable 1 (changed + 1)
            if (session.request enable) != #[0x13]: throw "CCCD_RESTORE_FAILED"
            session.response-sent
            migrated = true
            host.send link 4 indication
          if response:
            host.send link 4 response
            session.response-sent
    if error != "HCI_LINK_DISCONNECTED": throw (error or "MISSING_DISCONNECT")
    if not confirmed or reads != 4 or writes != 1: throw "INCOMPLETE_MIGRATION"
    if (replacement.value decoy) != #[99] or (replacement.value moved) != #[42]:
      throw "WRONG_FINAL_VALUES"
    print "CACHE_MIGRATION_PEER COMPLETE reads=4 writes=1 confirmed=true decoy-intact=true"
  finally:
    if session: session.close
    if host:
      host.close
      host.wait-closed
    else:
      controller.close
      controller.wait-closed
