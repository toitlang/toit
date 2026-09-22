// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.attribute-server as attributes
import ble.experimental.central
import ble.experimental.esp32
import ble.experimental.gatt-server
import ble.experimental.hci
import ble.experimental.signaling
import system

// Dedicated two-board test; no pairing, bond storage or Linux adapter.
run --peer-address/ByteArray?=null:
  controller := hci.Controller (esp32.Esp32Transport)
  host/central.Central? := null
  before := system.process-stats --gc
  retained := []
  try:
    info := hci.initialize controller
    host = central.Central controller --acl-length=info.acl-length --acl-count=info.acl-count
    debug "LATE_PARAMETER READY peripheral=$(not peer-address)"
    with-timeout --ms=60_000:
      3.repeat: | round/int |
        if peer-address:
          link := host.connect peer-address --address-type=0 --timeout=(Duration --s=15)
          request := link.receive
          if request.channel != 5 or request.payload != (signaling.parameter-request 1):
            throw "UNEXPECTED_PARAMETER_REQUEST"
          if round < 2:
            // Exercise the signaling verdict only; no controller update claim.
            host.send link 5 #[0x13, 1, 2, 0, round, 0]
          else:
            sleep --ms=750
          11.repeat: | index/int |
            if index == 1:
              host.send link 5 #[0x13, 1, 2, 0, 2, 0]
              host.send link 5 #[1, 1, 2, 0, 0xff, 0xff]
            host.send link 4 #[0x0a, 3, 0]
            response := link.receive
            if response.channel != 4 or response.payload != #[0x0b, 42, round]:
              throw "LATE_PARAMETER_READ_FAILED"
            retained.add response.payload
            system.process-stats --gc
          host.disconnect link
        else:
          database := attributes.Database
          database.add-service #[0xf0, 0xff]
          handle := database.add-characteristic #[0xf1, 0xff] --read --dynamic-read
          if handle != 3: throw "UNEXPECTED_HANDLE"
          link := host.accept #[2, 1, 6] --timeout=(Duration --s=20)
          server := gatt-server.Server host link database
          reads := 0
          try:
            server.request-parameters --timeout=(Duration --ms=500)
            server.serve-with-reads
                (: | request/attributes.ReadRequest |
                  if request.handle != handle: throw "UNEXPECTED_READ_HANDLE"
                  if server.parameter-status != (["accepted", "rejected", "timeout"][round]):
                    throw "UNEXPECTED_PARAMETER_STATUS"
                  reads++
                  system.process-stats --gc
                  request.reply #[42, round])
                (: | written/int value/ByteArray | unreachable)
            if reads != 11: throw "UNEXPECTED_READ_COUNT"
          finally:
            server.close
        debug "LATE_PARAMETER ROUND round=$round reads=11 peripheral=$(not peer-address)"
    system.process-stats --gc
    retained.size.repeat: | index/int |
      if retained[index] != #[0x0b, 42, index / 11]: throw "RETAINED_DATA_CHANGED"
  finally:
    if host:
      host.close
      host.wait-closed
    else:
      controller.close
      controller.wait-closed
  after := system.process-stats --gc
  gcs := after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT]
  if gcs < 33: throw "GC_NOT_OBSERVED"
  debug "LATE_PARAMETER COMPLETE peripheral=$(not peer-address) reads=33 full-gcs=$gcs retained=$(retained.size)"
