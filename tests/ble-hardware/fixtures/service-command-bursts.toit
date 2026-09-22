// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.service.client as service
import system
import .hci-echo as fixture

main: run

run --peer/ByteArray=#[0x3a, 0x0b, 0xa0, 3, 0xf7, 0x84]:
  if peer.size != 6: throw "INVALID_ARGUMENT"
  client := service.Client
  client.open --timeout=(Duration --s=10)
  try:
    session := client.configure
    uuid := fixture.wire-uuid "9f6c6200-8e2a-4b13-9e97-94f353eeb001"
    session.add-service uuid
    handle := session.add-characteristic (fixture.wire-uuid "9f6c6201-8e2a-4b13-9e97-94f353eeb001")
        --read
        --write-command
        --value=#[7]
    print "COMMAND_BURSTS_APP ADVERTISING"
    session.start (#[2, 1, 6, 17, 7] + uuid)
    print "COMMAND_BURSTS_APP READY"
    if session.peer != [peer, 0]: throw "WRONG_PEER"
    received := 0
    retained := []
    before := system.process-stats --gc
    started := Time.monotonic-us
    session.serve
        (: | _ | unreachable)
        (: | _ | unreachable)
        (: | actual/int value/ByteArray |
          if actual != handle or value != (fixture.payload received): throw "COMMAND_SEQUENCE_MISMATCH"
          received++
          retained.add value
          if retained.size > 4: retained.remove --at=0
          system.process-stats --gc
          retained.size.repeat: | index/int |
            if retained[index] != (fixture.payload (received - retained.size + index)):
              throw "RETAINED_COMMAND_CHANGED")
    after := system.process-stats --gc
    gcs := after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT]
    if received != 512 or gcs < received: throw "COMMAND_BURSTS_INCOMPLETE"
    print "COMMAND_BURSTS_APP COMPLETE received=$received retained=$(retained.size) full-gcs=$gcs elapsed-us=$(Time.monotonic-us - started)"
  finally:
    client.close
