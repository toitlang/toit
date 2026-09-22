// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Measures allocation through the public raw ATT boundary with a simulated peer.
// Includes peer work and GC instrumentation; does not measure radio throughput.
import ble.experimental.att
import ble.experimental.central
import ble.experimental.hci
import expect show *
import system
import ..ble-hci-test as fixture
import ..ble-mtu-server-test as wire

main:
  with-timeout --ms=60_000:
    [20, 512].do: measure it

measure size/int:
  radio := fixture.FakeTransport
  host := central.Central (hci.Controller radio) --acl-length=27 --acl-count=1 --receive-limit=517
  client/att.Client? := null
  request := #[0x12, 3, 0] + (wire.payload size)
  expected := request.copy
  responder := task::
    fixture.status-reply radio fixture.create-command
    radio.received.add fixture.connection-event
    wire.outgoing radio (wire.exchange 2 517)
    wire.incoming radio (wire.exchange 3 517)
    1100.repeat:
      wire.outgoing radio expected
      wire.incoming radio #[0x13]
  try:
    client = att.Client host (host.connect #[1, 2, 3, 4, 5, 6] --address-type=1) --mtu-limit=517
    expect-equals 517 client.exchange-mtu
    100.repeat: expect-equals #[0x13] (client.request request --response=0x13)
    before := system.process-stats --gc
    1000.repeat: expect-equals #[0x13] (client.request request --response=0x13)
    after := system.process-stats
    allocated := after[system.STATS-INDEX-BYTES-ALLOCATED-IN-OBJECT-HEAP] -
        before[system.STATS-INDEX-BYTES-ALLOCATED-IN-OBJECT-HEAP]
    system.process-stats --gc
    expect-equals expected request
    expect (not radio.closed)
    print "ATT_REQUEST_ALLOCATION COMPLETE count=1000 bytes=$size allocated=$allocated retained=true"
  finally:
    responder.cancel
    if client: client.close
    host.close
    host.wait-closed
