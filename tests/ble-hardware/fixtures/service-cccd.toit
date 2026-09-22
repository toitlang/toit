// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.service.client as service
import monitor
import system

// Separate application image: no protocol, bond, storage or provider imports.
// Handles are this fixture's provider-owned fixed schema, checked on both sides.
main arguments/List:
  cycle/int := arguments[0]
  resumed/bool := arguments[1]
  with-timeout --ms=55_000:
    client := service.Client
    client.open --timeout=(Duration --s=10)
    worker/Task? := null
    ended := monitor.Latch
    requested := monitor.Latch
    writes := 0
    serving-error/any := null
    try:
      if (catch: client.configure) != "CCCD_SERVICE_FIXED_DATABASE":
        throw "CCCD_SERVICE_ACCEPTED_ARBITRARY_LAYOUT"
      session := client.session
      session.peer
      worker = task::
        try:
          serving-error = catch:
            session.serve (: unreachable) (: unreachable): | handle/int bytes/ByteArray |
              if handle == 18:
                if bytes != #[1] or requested.has-value: throw "CCCD_SERVICE_BAD_CONTROL"
                requested.set true
              else:
                if resumed: throw "CCCD_SERVICE_UNEXPECTED_REWRITE"
                if handle == 13 and bytes == #[1, 0]: writes++
                else if handle == 16 and bytes == #[2, 0]: writes++
                else: throw "CCCD_SERVICE_BAD_WRITE"
          if serving-error and not requested.has-value:
            requested.set serving-error --exception
        finally:
          critical-do --no-respect-deadline: ended.set true
      requested.get
      state := session.security
      if not state.encrypted or not state.authenticated: throw "CCCD_SERVICE_APP_SECURITY"
      retained := #[cycle, 0, 42]
      before := system.process-stats --gc
      20.repeat: | sequence/int |
        session.set-value 12 #[cycle, sequence, 42]
        session.set-value 15 #[cycle, sequence, 43]
        if not (session.notify 12): throw "CCCD_SERVICE_NOTIFY_DISABLED"
        receipt := session.indicate 15 --timeout=(Duration --s=3)
        if not receipt: throw "CCCD_SERVICE_INDICATE_DISABLED"
        receipt.wait
        system.process-stats --gc
      receipt := session.indicate 8 --timeout=(Duration --s=3)
      if not receipt: throw "CCCD_SERVICE_CHANGED_DISABLED"
      receipt.wait
      after := system.process-stats --gc
      gcs := after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT]
      if gcs < 20 or retained != #[cycle, 0, 42]: throw "CCCD_SERVICE_APP_GC"
      print "CCCD_PERSIST SENT cycle=$cycle indications-confirmed=21"
      ended.get
      if serving-error: throw serving-error
      if writes != (resumed ? 0 : 2): throw "CCCD_SERVICE_APP_WRITE_COUNT"
      print "CCCD_SERVICE_APP COMPLETE cycle=$cycle resumed=$resumed pid=$(Process.current.id) notifications=20 indications=20 service-changed=1 full-gcs=$gcs application-cccd-writes=$writes retained=true"
    finally:
      critical-do --no-respect-deadline:
        client.close
        if worker:
          worker.cancel
          with-timeout --ms=3_000: ended.get
