// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.service.requests as bridge
import expect show *
import monitor
import system

// A failed or expired submission must leave room for a fresh request. Sweep
// real heap pressure across offer allocation and response-wait setup.
main:
  slots := List 16384
  value := ByteArray 200 --initial=42
  set-max-heap-size_ (256 * 1024)
  failures := 0
  expired := 0
  with-timeout --ms=30_000:
    64.repeat: | trial/int |
      requests := bridge.Requests --value-limit=512
      filled := 0
      failure := catch:
        while filled < slots.size:
          slots[filled] = ByteArray 8 --initial=42
          filled++
      if failure != "ALLOCATION_FAILED" and failure != "OUT_OF_MEMORY":
        throw "PRESSURE_NOT_REACHED"
      (trial * 16).repeat: slots[filled - 1 - it] = null
      error := catch:
        requests.exchange bridge.VALIDATE-WRITE 3 18 value (Time.monotonic-us + 10_000)
      slots.fill null
      system.process-stats --gc
      if error == "ALLOCATION_FAILED" or error == "OUT_OF_MEMORY": failures++
      else if error == DEADLINE-EXCEEDED-ERROR: expired++
      else: throw "UNEXPECTED_OFFER_RESULT $error"
      ended := monitor.Latch
      worker := task::
        result := catch:
          expect-equals [0, #[]]
              requests.exchange bridge.VALIDATE-WRITE 5 18 #[7] (Time.monotonic-us + 1_000_000)
        ended.set result
      try:
        with-timeout --ms=100:
          record := requests.next
          expect-equals [bridge.VALIDATE-WRITE, 5, 18] record[1..4]
          expect-equals #[7] record[5]
          requests.reply record[0]
          expect-null ended.get
      finally:
        critical-do --no-respect-deadline:
          requests.close
          worker.cancel
      print "OFFER_PRESSURE ROUND trial=$trial error=$error"
    if failures == 0 or expired == 0: throw "PRESSURE_BOUNDARY_NOT_COVERED"
    print "OFFER_PRESSURE COMPLETE failures=$failures expired=$expired"
