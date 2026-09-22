// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.attribute-server as attributes
import ble.experimental.central as central
import ble.experimental.esp32 as esp32
import ble.experimental.gatt-server as gatt
import ble.experimental.hci as hci
import ble.experimental.transport
import system

main:
  run

run --timeout/Duration=(Duration --s=100) --radio/transport.Transport?=null
    --reads/int=600 --hold-last/bool=false:
  with-timeout timeout:
    controller := hci.Controller (radio or (esp32.Esp32Transport))
    host/central.Central? := null
    count := 0
    retained := []
    held := false
    before := system.process-stats
    try:
      info := hci.initialize controller --receive-acl-packets=4
      host = central.Central controller --acl-length=info.acl-length --acl-count=info.acl-count
      database := attributes.Database
      database.add-service #[0xf0, 0xff]
      handle := database.add-characteristic #[0xf1, 0xff] --read --dynamic-read
      if handle != 3: throw "MIXED_UPDATE_PEER_HANDLE"
      print "MIXED_UPDATE_PEER READY"
      link := host.accept #[2, 1, 6]
      if link.info.address != #[0xfe, 0x50, 0xc1, 0xfa, 0x12, 0xf4] or link.info.address-type != 0:
        throw "MIXED_UPDATE_PEER_WRONG_CENTRAL"
      server := gatt.Server host link database
          --handler-timeout=(Duration --s=(hold-last ? 10 : 1))
      server.serve-with-reads
          (: | request/attributes.ReadRequest |
            if request.handle != handle: throw "MIXED_UPDATE_PEER_UNEXPECTED_READ"
            if hold-last and count == reads and not held:
              held = true
              print "MIXED_LOST_PEER PENDING reads=$count"
              sleep --ms=20_000
              throw "MIXED_LOST_PEER_UNEXPECTED_REPLY"
            if count >= reads: throw "MIXED_UPDATE_PEER_UNEXPECTED_READ"
            bytes := #[count & 0xff, count >> 8, 42]
            if retained.size < 4: retained.add bytes
            if count % 10 == 0: system.process-stats --gc
            retained.size.repeat:
              if retained[it] != #[it, 0, 42]: throw "MIXED_UPDATE_PEER_RETAINED_CHANGED"
            count++
            request.reply bytes)
          (: | _ _ | unreachable)
      if count != reads or held != hold-last: throw "MIXED_UPDATE_PEER_READ_COUNT"
    finally:
      critical-do --no-respect-deadline:
        if host:
          host.close
          host.wait-closed
        else:
          controller.close
          controller.wait-closed
        if hold-last:
          // Disconnect cancels the serving task while its read block waits.
          // Record the checked terminal state from cleanup in that case too.
          after := system.process-stats
          gcs := after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT]
          if count != reads or not held or gcs < reads / 10:
            throw "MIXED_LOST_PEER_INCOMPLETE"
          retained.size.repeat:
            if retained[it] != #[it, 0, 42]: throw "MIXED_UPDATE_PEER_RETAINED_CHANGED"
          print "MIXED_LOST_PEER COMPLETE reads=$reads pending=1 retained=4 full-gcs=$gcs"
    if hold-last: return
    after := system.process-stats
    gcs := after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT]
    if gcs < reads / 10: throw "MIXED_UPDATE_PEER_GC_MISSING"
    print "MIXED_UPDATE_PEER COMPLETE reads=$reads retained=4 full-gcs=$gcs"
