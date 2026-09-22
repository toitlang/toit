// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.receive-credits
import expect show *
import system
import .ble-receive-credits-test as fixture

main: run

run --heap-limit/int=(256 * 1024) --ballast-slots/int=16384 --ballast-size/int=8:
  slots := List ballast-slots
  set-max-heap-size_ heap-limit
  failures := 0
  with-timeout --ms=30_000:
    64.repeat: | trial/int |
      credits := receive-credits.ReceiveCredits 32
      receipts := []
      packets := []
      16.repeat: | handle/int |
        credits.connected handle
        2.repeat:
          bytes := fixture.packet handle
          packets.add bytes
          receipts.add (credits.received bytes)
      filled := 0
      failure := catch:
        while filled < slots.size:
          slots[filled] = ByteArray ballast-size --initial=42
          filled++
      if failure != "ALLOCATION_FAILED" and failure != "OUT_OF_MEMORY":
        throw "PRESSURE_NOT_REACHED"
      trial.repeat: slots[filled - 1 - it] = null
      error := catch: credits.close
      slots.fill null
      system.process-stats --gc
      if error:
        if error != "ALLOCATION_FAILED" and error != "OUT_OF_MEMORY": throw error
        failures++
      // A repeated close must finish cleanup even if an earlier attempt failed.
      credits.close
      expect-equals 0 credits.outstanding
      receipts.do: | receipt/receive-credits.Receipt |
        expect (not receipt.can-submit)
        receipt.finish --no-submitted
      packets.do: expect-null (credits.find it)
      print "RX_CLOSE_PRESSURE ROUND trial=$trial error=$error"
    print "RX_CLOSE_PRESSURE COMPLETE rounds=64 failures=$failures"
