// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Peripheral-initiated connection parameter updates: each request carries a
// new identifier, a refusal is reported, a late answer to an earlier request
// is ignored, and an accepted request completes when the central applies it.

import ble.experimental.attribute-server as attributes
import ble.experimental.central
import ble.experimental.gatt-server
import ble.experimental.hci
import ble.experimental.signaling
import expect show *
import monitor
import .ble-fixture as fixture
import .ble-key-reply-test as keys

main:
  with-timeout --ms=10_000:
    database := attributes.Database
    database.add-service #[0xf0, 0xff]
    database.add-characteristic #[0xf1, 0xff] --read --value=#[1]
    transport := fixture.FakeTransport
    transport.auto-disconnect = true
    host := central.Central (hci.Controller transport)
    responder := task::
      keys.establish transport
      // First request: 30 to 50 ms with latency 2; the central refuses.
      fixture.att-sent transport (signaling.parameter-request 1 --interval=24 --interval-max=40 --latency=2) --channel=5
      transport.received.add (fixture.att-event #[0x13, 1, 2, 0, 1, 0] --channel=5)
      // Second request uses identifier 2; a late answer for 1 changes nothing.
      fixture.att-sent transport (signaling.parameter-request 2 --interval=12) --channel=5
      transport.received.add (fixture.att-event #[0x13, 1, 2, 0, 0, 0] --channel=5)
      transport.received.add (fixture.att-event #[0x13, 2, 2, 0, 0, 0] --channel=5)
      transport.received.add #[4, 0x3e, 10, 3, 0, 0x34, 2, 12, 0, 0, 0, 0x90, 1]
      transport.received.add #[4, 5, 4, 0, 0x34, 2, 0x13]
    server/gatt-server.Server? := null
    try:
      link := host.accept #[2, 1, 6]
      server = gatt-server.Server host link database
      serving := task:: catch: server.serve: | _ _ | null
      expect-throw "L2CAP_PARAMETERS_REJECTED":
        server.update-parameters --interval-min=24 --interval-max=40 --latency=2
      expect-equals "rejected" server.parameter-status
      applied := server.update-parameters --interval-min=12
      expect-equals 12 applied.interval
      expect-equals 12 link.parameters.interval
      expect-equals "accepted" server.parameter-status
      fixture.wait-ended link
    finally:
      if server: server.close
      responder.cancel
      host.close
      host.wait-closed
