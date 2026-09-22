// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.service.client as service
import monitor
import system
import .hci-echo as fixture

main:
  with-timeout --ms=90_000: run

run:
  client := service.Client
  client.open --timeout=(Duration --s=10)
  serving/Task? := null
  ended := monitor.Latch
  before := system.process-stats --gc
  try:
    session := client.configure --value-limit=512 --mtu-limit=517
    uuid := fixture.wire-uuid "9f6c4000-8e2a-4b13-9e97-94f353eeb001"
    session.add-service uuid
    value := session.add-characteristic (fixture.wire-uuid "9f6c4001-8e2a-4b13-9e97-94f353eeb001")
        --indicate
        --encrypted
    status := session.add-characteristic (fixture.wire-uuid "9f6c4002-8e2a-4b13-9e97-94f353eeb001")
        --read
        --dynamic-read
        --encrypted
    if value != 12 or status != 15: throw "UNEXPECTED_FIXTURE_LAYOUT"
    session.start (#[2, 1, 6, 17, 7] + uuid)
    print "SERVICE_INDICATIONS READY"
    session.peer
    enabled := monitor.Latch
    completed := monitor.Latch
    serving = task::
      try:
        error := catch:
          session.serve
              (: | request/service.Request |
                if request.handle != status: throw "UNEXPECTED_READ"
                completed.get
                request.reply #[100])
              (: unreachable)
              (: | handle/int bytes/ByteArray |
                if handle != value + 1 or bytes != #[2, 0]: throw "UNEXPECTED_CCCD"
                enabled.set true)
        if error:
          if not enabled.has-value: enabled.set error --exception
          throw error
      finally:
        critical-do --no-respect-deadline: ended.set true
    enabled.get
    if session.mtu != 517: throw "UNEXPECTED_NEGOTIATED_MTU"
    retained := []
    100.repeat: | sequence/int |
      bytes := payload sequence
      if sequence % 10 == 0: retained.add bytes
      session.set-value value bytes
      receipt := session.indicate value
      if not receipt: throw "INDICATION_NOT_ENABLED"
      system.process-stats --gc
      receipt.wait
    retained.size.repeat: | index/int |
      if retained[index] != (payload (index * 10)): throw "RETAINED_VALUE_CHANGED"
    after := system.process-stats --gc
    gcs := after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT]
    if gcs < 100: throw "GC_CHECK_INCOMPLETE"
    print "SERVICE_INDICATIONS confirmed=100 mtu=517 retained=$(retained.size) full-gcs=$gcs"
    completed.set true
    ended.get
    print "SERVICE_INDICATIONS COMPLETE confirmed=100"
  finally:
    critical-do --no-respect-deadline:
      client.close
      if serving:
        serving.cancel
        with-timeout --ms=3_000: ended.get

payload sequence/int -> ByteArray: return ByteArray 512: (sequence + it) % 251
