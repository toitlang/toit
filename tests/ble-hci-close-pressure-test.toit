// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.hci
import expect show *
import io
import system
import .ble-fixture as fixture
import .ble-hci-receive-flow-test as flow
import .ble-receive-credits-test as packets

main:
  [1, 16].do: run it

run handles/int:
  slots := List 16384
  set-max-heap-size_ (256 * 1024)
  failures := 0
  with-timeout --ms=30_000:
    64.repeat: | trial/int |
      radio := fixture.FakeTransport
      controller := hci.Controller radio
      count := handles == 1 ? 1 : 32
      initializer := task:: flow.initialize-radio radio --count=count
      close-error := null
      try:
        hci.initialize controller --receive-acl-packets=count
        handles.repeat: | handle/int |
          event := fixture.connection-event.copy
          io.LITTLE-ENDIAN.put-uint16 event 5 handle
          radio.received.add event
          expect-identical event controller.receive
          (count / handles).repeat:
            bytes := packets.packet handle
            radio.received.add bytes
            expect-identical bytes controller.receive
        filled := 0
        failure := catch:
          while filled < slots.size:
            slots[filled] = ByteArray 8 --initial=42
            filled++
        if failure != "ALLOCATION_FAILED" and failure != "OUT_OF_MEMORY":
          throw "PRESSURE_NOT_REACHED"
        (trial * 16).repeat: slots[filled - 1 - it] = null
        close-error = catch: controller.close
        slots.fill null
        system.process-stats --gc
        if close-error:
          if close-error != "ALLOCATION_FAILED" and close-error != "OUT_OF_MEMORY": throw close-error
          failures++
        controller.close
        expect radio.closed
        with-timeout --ms=100: controller.wait-closed
      finally:
        slots.fill null
        initializer.cancel
        controller.close
        radio.close
      print "HCI_CLOSE_PRESSURE ROUND handles=$handles trial=$trial error=$close-error"
    if failures == 0 or failures == 64: throw "PRESSURE_BOUNDARY_NOT_COVERED"
    print "HCI_CLOSE_PRESSURE COMPLETE handles=$handles rounds=64 failures=$failures"
