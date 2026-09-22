// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.service.requests as bridge
import expect show *
import monitor
import system

main:
  slots := List 16384
  proposed := ByteArray 200 --initial=42
  set-max-heap-size_ (256 * 1024)
  failures := 0
  successes := 0
  with-timeout --ms=30_000:
    64.repeat: | trial/int |
      requests := bridge.Requests --value-limit=512
      request-error := null
      ended := monitor.Latch
      worker := task::
        error := catch:
          expect-equals [0, #[]]
              requests.exchange bridge.VALIDATE-WRITE 3 18 proposed (Time.monotonic-us + 5_000_000)
        ended.set error
      try:
        // A rejected premature reply proves the fresh mailbox has an offer;
        // it neither consumes nor acknowledges the request.
        with-timeout --ms=1_000:
          while true:
            error := catch: requests.reply 1
            if error == "GATT_REQUEST_NOT_DELIVERED": break
            expect-equals "GATT_REQUEST_EXPIRED" error
            sleep --ms=1
        filled := 0
        failure := catch:
          while filled < slots.size:
            slots[filled] = ByteArray 8 --initial=42
            filled++
        if failure != "ALLOCATION_FAILED" and failure != "OUT_OF_MEMORY":
          throw "PRESSURE_NOT_REACHED"
        trial.repeat: slots[filled - 1 - it] = null
        record/List? := null
        request-error = catch: record = requests.next
        slots.fill null
        system.process-stats --gc
        if request-error:
          if request-error != "ALLOCATION_FAILED" and request-error != "OUT_OF_MEMORY": throw request-error
          failures++
          with-timeout --ms=100: record = requests.next
        else:
          successes++
        expect-equals [1, bridge.VALIDATE-WRITE, 3, 18] record[..4]
        expect-equals proposed record[5]
        requests.reply record[0]
        expect-null ended.get
      finally:
        slots.fill null
        critical-do --no-respect-deadline:
          requests.close
          worker.cancel
      print "REQUEST_PRESSURE ROUND trial=$trial error=$request-error"
    if failures == 0 or successes == 0: throw "PRESSURE_BOUNDARY_NOT_COVERED"
    print "REQUEST_PRESSURE COMPLETE failures=$failures successes=$successes"
