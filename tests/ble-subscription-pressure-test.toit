// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.att
import ble.experimental.central
import ble.experimental.hci
import expect show *
import system
import .ble-hci-test as fixture
import .ble-mtu-server-test as wire
import .ble-subscriptions-test as subscriptions

main:
  slots := List 16384
  set-max-heap-size_ (256 * 1024)
  failures := 0
  with-timeout --ms=30_000:
    256.repeat: | trial/int |
      transport := fixture.FakeTransport
      host := central.Central (hci.Controller transport)
      client/att.Client? := null
      expected := ByteArray 20 --initial=42
      responder := task::
        fixture.status-reply transport fixture.create-command
        transport.received.add fixture.connection-event
        subscriptions.cccd transport 4 1
        wire.incoming transport (#[0x1b, 3, 0] + expected)
        wire.incoming transport (#[0x1b, 3, 0] + expected)
        subscriptions.barrier transport
        subscriptions.cccd transport 4 0
      try:
        client = att.Client host (host.connect #[1, 2, 3, 4, 5, 6] --address-type=1)
        client.subscribe 3 --cccd=4: | stream/att.Subscription |
          expect-equals #[7] (client.read 1)
          expect-equals expected stream.receive
          expect-equals 1 client.queued-updates
          filled := 0
          exhaustion := catch:
            while filled < slots.size:
              slots[filled] = ByteArray 8
              filled++
          if exhaustion != "ALLOCATION_FAILED" and exhaustion != "OUT_OF_MEMORY":
            throw "PRESSURE_NOT_REACHED"
          trial.repeat: slots[filled - 1 - it] = null
          received/ByteArray? := null
          error := catch: received = stream.receive
          slots.fill null
          system.process-stats --gc
          if error:
            if error != "ALLOCATION_FAILED" and error != "OUT_OF_MEMORY": throw error
            failures++
            expect-equals 1 client.queued-updates
            received = stream.receive
          expect-equals expected received
          expect-equals 0 client.queued-updates
      finally:
        slots.fill null
        responder.cancel
        if client: client.close
        host.close
        host.wait-closed
    expect (failures > 0)
    expect (failures < 256)
    print "SUBSCRIPTION_PRESSURE COMPLETE rounds=256 failures=$failures"
