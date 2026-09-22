// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.hci
import expect show *
import system
import .ble-hci-test as fixture

main:
  slots := List 16384
  parameters := ByteArray 200 --initial=42
  timeout := Duration --ms=20
  set-max-heap-size_ (256 * 1024)
  failures := 0
  expired := 0
  recovered := 0
  aborted := 0
  with-timeout --ms=30_000:
    256.repeat: | trial/int |
      radio := fixture.FakeTransport
      controller := hci.Controller radio
      initializer := task:: fixture.reply radio #[1, 3, 12, 0] #[]
      error := null
      try:
        // Start and exercise the reader before exhausting its shared heap.
        controller.command hci.RESET
        filled := 0
        failure := catch:
          while filled < slots.size:
            slots[filled] = ByteArray 8 --initial=42
            filled++
        if failure != "ALLOCATION_FAILED" and failure != "OUT_OF_MEMORY":
          throw "PRESSURE_NOT_REACHED"
        (trial * 4).repeat: slots[filled - 1 - it] = null
        // The simulated vendor command has no reply, exercising timeout cleanup
        // in addition to allocation failure before or during submission.
        error = catch: controller.command 0xfc01 parameters --timeout=timeout
        slots.fill null
        system.process-stats --gc
        if error == "ALLOCATION_FAILED" or error == "OUT_OF_MEMORY": failures++
        else if error == DEADLINE-EXCEEDED-ERROR: expired++
        else: throw "UNEXPECTED_COMMAND_RESULT $error"
        if error == DEADLINE-EXCEEDED-ERROR: expect radio.closed
        if not radio.closed:
          // A pre-submission failure may leave the controller usable. Check
          // that it has neither a stale command nor a consumed command credit.
          responder := task:: fixture.reply radio #[1, 3, 12, 0] #[]
          try:
            controller.command hci.RESET --timeout=timeout
          finally:
            responder.cancel
          recovered++
        else if error != DEADLINE-EXCEEDED-ERROR:
          aborted++
        controller.close
        expect radio.closed
        with-timeout --ms=100: controller.wait-closed
        expect-equals (ByteArray 200 --initial=42) parameters
      finally:
        slots.fill null
        initializer.cancel
        controller.close
        radio.close
      print "COMMAND_PRESSURE ROUND trial=$trial error=$error"
    print "COMMAND_PRESSURE SUMMARY failures=$failures expired=$expired recovered=$recovered aborted=$aborted"
    if failures == 0 or expired == 0 or recovered == 0 or aborted == 0:
      throw "PRESSURE_BOUNDARY_NOT_COVERED"
    print "COMMAND_PRESSURE COMPLETE"
