// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.service.client as service
import monitor
import system

// Only service RPC is retained in this application image. The provider owns
// the layout, revision, security and migration; application CCCD writes fail.
main arguments/List:
  stage/string := arguments[0]
  cycle/int := arguments[1]
  with-timeout --ms=55_000:
    client := service.Client
    client.open --timeout=(Duration --s=10)
    ended := monitor.Latch
    requested := monitor.Latch
    worker/Task? := null
    serving-error/any := null
    try:
      if (catch: client.configure) != "CCCD_MIGRATE_FIXED_DATABASE":
        throw "CCCD_MIGRATE_ACCEPTED_ARBITRARY_LAYOUT"
      session := client.session
      session.peer
      worker = task::
        try:
          serving-error = catch:
            session.serve (: unreachable) (: unreachable): | handle/int bytes/ByteArray |
              if handle != 21 or bytes != #[(stage == "migrate" ? 0 : 1)] or requested.has-value:
                throw "CCCD_MIGRATE_UNEXPECTED_WRITE"
              requested.set true
          if serving-error and not requested.has-value: requested.set serving-error --exception
        finally:
          critical-do --no-respect-deadline: ended.set true
      requested.get
      state := session.security
      if not state.encrypted or not state.authenticated: throw "CCCD_MIGRATE_APP_SECURITY"
      retained := #[cycle, 0, 42]
      before := system.process-stats --gc
      if stage == "migrate":
        if session.notify 15: throw "CCCD_MIGRATE_PUBLISHED_BEFORE_CONFIRMATION"
        print "CCCD_MIGRATE BLOCKED cycle=$cycle notification-suppressed=true"
      else:
        20.repeat: | sequence/int |
          session.set-value 15 #[cycle, sequence, 42]
          session.set-value 18 #[cycle, sequence, 43]
          if not (session.notify 15): throw "CCCD_MIGRATE_NOTIFY_DISABLED"
          receipt := session.indicate 18 --timeout=(Duration --s=3)
          if not receipt: throw "CCCD_MIGRATE_INDICATE_DISABLED"
          receipt.wait
          system.process-stats --gc
        print "CCCD_MIGRATE SENT cycle=$cycle indications-confirmed=20"
      after := system.process-stats --gc
      gcs := after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT]
      if gcs < (stage == "migrate" ? 1 : 20) or retained != #[cycle, 0, 42]:
        throw "CCCD_MIGRATE_APP_GC"
      ended.get
      if serving-error: throw serving-error
      print "CCCD_MIGRATE_APP COMPLETE stage=$stage cycle=$cycle full-gcs=$gcs cccd-writes=0 retained=true"
    finally:
      critical-do --no-respect-deadline:
        client.close
        if worker:
          worker.cancel
          with-timeout --ms=3_000: ended.get
