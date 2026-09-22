// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.service.requests as bridge
import expect show *
import monitor
import system

// A reply that cannot allocate its owned value must remain retryable.
main:
  slots := List 16384
  value := ByteArray 200 --initial=42
  set-max-heap-size_ (256 * 1024)
  failures := 0
  successes := 0
  with-timeout --ms=30_000:
    64.repeat: | trial/int |
      requests := bridge.Requests --value-limit=512
      ended := monitor.Latch
      response/List? := null
      worker := task::
        error := catch:
          response = requests.exchange bridge.READ 3 10 #[] (Time.monotonic-us + 5_000_000)
        ended.set error
      reply-error := null
      try:
        record := requests.next
        expect-equals [1, bridge.READ, 3, 10] record[..4]
        filled := 0
        failure := catch:
          while filled < slots.size:
            slots[filled] = ByteArray 8 --initial=42
            filled++
        if failure != "ALLOCATION_FAILED" and failure != "OUT_OF_MEMORY":
          throw "PRESSURE_NOT_REACHED"
        trial.repeat: slots[filled - 1 - it] = null
        reply-error = catch: requests.reply record[0] --value=value
        slots.fill null
        system.process-stats --gc
        if reply-error:
          if reply-error != "ALLOCATION_FAILED" and reply-error != "OUT_OF_MEMORY": throw reply-error
          failures++
          requests.reply record[0] --value=value
        else:
          successes++
        // Neither successful submission nor its retry may retain caller storage.
        value.fill 99
        system.process-stats --gc
        expect-null ended.get
        expect-equals 0 response[0]
        expect-equals (ByteArray 200 --initial=42) response[1]
        value.fill 42
      finally:
        slots.fill null
        critical-do --no-respect-deadline:
          requests.close
          worker.cancel
      print "REPLY_PRESSURE ROUND trial=$trial error=$reply-error"
    if failures == 0 or successes == 0: throw "PRESSURE_BOUNDARY_NOT_COVERED"
    print "REPLY_PRESSURE COMPLETE failures=$failures successes=$successes"
