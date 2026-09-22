// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.att
import ble.experimental.central
import ble.experimental.hci
import expect show *
import system
import .ble-fixture as fixture
import .ble-mtu-server-test as wire

main:
  slots := List 16384
  set-max-heap-size_ (256 * 1024)
  failures := 0
  with-timeout --ms=30_000:
    256.repeat: | trial/int |
      radio := fixture.FakeTransport
      host := central.Central (hci.Controller radio)
      client/att.Client? := null
      expected := ByteArray 20 --initial=42
      indication := trial % 2 == 0
      responder := task::
        fixture.status-reply radio fixture.create-command
        radio.received.add fixture.connection-event
        wire.outgoing radio #[0x0a, 1, 0]
        2.repeat:
          wire.incoming radio (#[indication ? 0x1d : 0x1b, 3, 0] + expected)
          if indication: wire.outgoing radio #[0x1e]
        wire.incoming radio #[0x0b, 7]
      try:
        client = att.Client host (host.connect #[1, 2, 3, 4, 5, 6] --address-type=1)
        expect-equals #[7] (client.read 1)
        warm := client.receive-notification
        expect-equals expected warm.value
        expect-equals 1 client.queued-updates
        filled := 0
        exhaustion := catch:
          while filled < slots.size:
            slots[filled] = ByteArray 8
            filled++
        if exhaustion != "ALLOCATION_FAILED" and exhaustion != "OUT_OF_MEMORY":
          throw "PRESSURE_NOT_REACHED"
        trial.repeat: slots[filled - 1 - it] = null
        received/att.Notification? := null
        error := catch: received = client.receive-notification
        slots.fill null
        system.process-stats --gc
        if error:
          if error != "ALLOCATION_FAILED" and error != "OUT_OF_MEMORY": throw error
          failures++
          expect-equals 1 client.queued-updates
          received = client.receive-notification
        expect-equals 3 received.handle
        expect-equals indication received.indication
        expect-equals expected received.value
        expect-equals expected warm.value
        expect-equals 0 client.queued-updates
      finally:
        slots.fill null
        responder.cancel
        if client: client.close
        host.close
        host.wait-closed
    expect (0 < failures < 256)
    print "NOTIFICATION_PRESSURE COMPLETE rounds=256 failures=$failures"
