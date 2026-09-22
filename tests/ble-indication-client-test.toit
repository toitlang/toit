// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.att
import ble.experimental.central
import ble.experimental.hci
import expect show *
import monitor
import system
import .ble-fixture as fixture
import .ble-mtu-server-test as wire

main:
  with-timeout --ms=15_000:
    during-request
    scoped
    overflow

during-request:
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport) --receive-limit=517
  client/att.Client? := null
  responder := task::
    fixture.status-reply transport fixture.create-command
    transport.received.add fixture.connection-event
    wire.outgoing transport #[0x0a, 3, 0]
    // Invalid indications still need confirmation and must not satisfy the read.
    [#[0x1d], #[0x1d, 0, 0, 9], (#[0x1d, 3, 0] + (ByteArray 21))].do:
      wire.incoming transport it
      wire.outgoing transport #[0x1e]
    wire.incoming transport #[0x1d, 3, 0, 7]
    wire.outgoing transport #[0x1e]
    wire.incoming transport #[0x0b, 8]
    wire.outgoing transport (wire.exchange 2 517)
    wire.incoming transport (wire.exchange 3 517)
    // The negotiated MTU does not lift the 512-byte attribute-value bound.
    wire.incoming transport (#[0x1d, 3, 0] + (wire.payload 513))
    wire.outgoing transport #[0x1e]
    wire.incoming transport (#[0x1d, 3, 0] + (wire.payload 512))
    wire.outgoing transport #[0x1e]
    wire.incoming transport #[0x1b, 3, 0, 6]
  try:
    client = att.Client host (host.connect #[1, 2, 3, 4, 5, 6] --address-type=1) --mtu-limit=517
    expect-equals #[8] (client.read 3)
    small := client.receive-notification
    expect small.indication
    expect-equals 3 small.handle
    expect-equals #[7] small.value
    expect-equals 517 client.exchange-mtu
    large := client.receive-notification
    expect large.indication
    system.process-stats --gc
    expect-equals (wire.payload 512) large.value
    expect-equals #[7] small.value
    notification := client.receive-notification
    expect (not notification.indication)
    expect-equals #[6] notification.value
  finally:
    responder.cancel
    if client: client.close
    host.close
    host.wait-closed

scoped:
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport)
  client/att.Client? := null
  stream/att.Subscription? := null
  responder := task::
    fixture.status-reply transport fixture.create-command
    transport.received.add fixture.connection-event
    wire.outgoing transport #[0x12, 4, 0, 2, 0]
    // The indication may arrive before the CCCD write response.
    wire.incoming transport #[0x1d, 3, 0, 9]
    wire.outgoing transport #[0x1e]
    wire.incoming transport #[0x13]
    wire.outgoing transport #[0x12, 4, 0, 0, 0]
    wire.incoming transport #[0x1d, 3, 0]
    wire.outgoing transport #[0x1e]
    wire.incoming transport #[0x13]
  try:
    client = att.Client host (host.connect #[1, 2, 3, 4, 5, 6] --address-type=1)
    expect-throw "BODY_FAILED":
      client.subscribe 3 --cccd=4 --indications: | subscription/att.Subscription |
        stream = subscription
        expect-equals #[9] subscription.receive
        throw "BODY_FAILED"
    expect-throw "ATT_SUBSCRIPTION_CLOSED": stream.receive
  finally:
    responder.cancel
    if client: client.close
    host.close
    host.wait-closed

overflow:
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport)
  client/att.Client? := null
  completed := monitor.Latch
  responder := task::
    fixture.status-reply transport fixture.create-command
    transport.received.add fixture.connection-event
    33.repeat:
      wire.incoming transport #[0x1d, 3, 0, 7]
      wire.outgoing transport #[0x1e]
    // A request barrier ensures the last confirmed indication has been queued.
    wire.outgoing transport #[0x0a, 3, 0]
    wire.incoming transport #[0x0b, 8]
    completed.set true
  try:
    client = att.Client host (host.connect #[1, 2, 3, 4, 5, 6] --address-type=1)
    // Let the reader confirm independently of application consumption.
    with-timeout --ms=3_000:
      while client.dropped-notifications == 0: sleep --ms=1
    expect-equals #[8] (client.read 3)
    completed.get
    expect-equals 1 client.dropped-notifications
    expect-throw "ATT_NOTIFICATION_OVERFLOW": client.receive-notification
  finally:
    responder.cancel
    if client: client.close
    host.close
    host.wait-closed
