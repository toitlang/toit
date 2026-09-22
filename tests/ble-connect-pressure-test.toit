// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.central
import ble.experimental.hci
import expect show *
import system
import .ble-fixture as fixture

main:
  slots := List 16384
  address := #[1, 2, 3, 4, 5, 6]
  timeout := Duration --ms=20
  set-max-heap-size_ (256 * 1024)
  recovered := 0
  failures := 0
  expired := 0
  with-timeout --ms=30_000:
    128.repeat: | trial/int |
      radio := fixture.FakeTransport
      controller := hci.Controller radio
      host := central.Central controller
      initializer := task:: fixture.reply radio #[1, 3, 12, 0] #[]
      try:
        controller.command hci.RESET
        filled := 0
        exhaustion := catch:
          while filled < slots.size:
            slots[filled] = ByteArray 8
            filled++
        if exhaustion != "OUT_OF_MEMORY" and exhaustion != "ALLOCATION_FAILED":
          throw "PRESSURE_NOT_REACHED"
        (trial * 4).repeat: slots[filled - 1 - it] = null
        error := catch: host.connect address --address-type=1 --timeout=timeout
        slots.fill null
        system.process-stats --gc
        if error == "OUT_OF_MEMORY" or error == "ALLOCATION_FAILED": failures++
        else if error == DEADLINE-EXCEEDED-ERROR: expired++
        else: throw "UNEXPECTED_CONNECT_RESULT $error"
        if not radio.closed:
          responder := task::
            fixture.status-reply radio fixture.create-command
            event := fixture.connection-event.copy
            event[4] = 2
            radio.received.add event
          try:
            retry-error := catch: host.connect address --address-type=1
            expect (retry-error is central.ConnectionError)
            expect-equals 2 retry-error.status
          finally:
            responder.cancel
          recovered++
      finally:
        slots.fill null
        initializer.cancel
        host.close
        host.wait-closed
      print "CONNECT_PRESSURE ROUND trial=$trial"
    expect (failures > 0 and expired > 0 and recovered > 0)
    print "CONNECT_PRESSURE COMPLETE failures=$failures expired=$expired recovered=$recovered"
