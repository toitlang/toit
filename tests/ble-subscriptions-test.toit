// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.att
import ble.experimental.central
import ble.experimental.hci
import expect show *
import monitor
import system
import .ble-hci-test as fixture
import .ble-mtu-server-test as wire

main:
  with-timeout --ms=10_000:
    isolated-overflow
    shared-budget
    close-wakes-streams

cccd transport handle/int bits/int:
  bytes := #[0x12, 0, 0, 0, 0]
  bytes[1] = handle
  bytes[3] = bits
  wire.outgoing transport bytes
  wire.incoming transport #[0x13]

barrier transport:
  wire.outgoing transport #[0x0a, 1, 0]
  wire.incoming transport #[0x0b, 7]

isolated-overflow:
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport)
  client/att.Client? := null
  responder := task::
    fixture.status-reply transport fixture.create-command
    transport.received.add fixture.connection-event
    cccd transport 9 2
    cccd transport 4 1
    3.repeat: wire.incoming transport #[0x1b, 3, 0, 5]
    wire.outgoing transport #[0x0a, 1, 0]
    wire.incoming transport #[0x1d, 8, 0, 1, 0, 0xff, 0xff]
    wire.outgoing transport #[0x1e]
    wire.incoming transport #[0x0b, 7]
    cccd transport 4 0
    wire.outgoing transport #[0x0a, 1, 0]
    wire.incoming transport #[0x1d, 8, 0, 2, 0, 3, 0]
    wire.outgoing transport #[0x1e]
    wire.incoming transport #[0x0b, 7]
    cccd transport 9 0
  try:
    client = att.Client host (host.connect #[1, 2, 3, 4, 5, 6] --address-type=1)
    client.subscribe 8 --cccd=9 --indications: | changes/att.Subscription |
      client.subscribe 3 --cccd=4 --queue-limit=2: | data/att.Subscription |
        expect-throw "ATT_SUBSCRIPTION_BUSY": client.subscribe 3 --cccd=5: unreachable
        expect-throw "ATT_SUBSCRIPTION_BUSY": client.subscribe 2 --cccd=4: unreachable
        expect-equals #[7] (client.read 1)
        expect-equals 3 client.queued-updates
        expect-equals 1 data.dropped
        expect-throw "ATT_NOTIFICATION_OVERFLOW": data.receive
        retained := changes.receive
        system.process-stats --gc
        expect-equals #[1, 0, 0xff, 0xff] retained
      expect-equals #[7] (client.read 1)
      expect-equals 1 client.queued-updates
      expect-equals #[2, 0, 3, 0] changes.receive
      expect-equals 0 changes.dropped
    expect-equals 0 client.queued-updates
  finally:
    responder.cancel
    if client: client.close
    host.close
    host.wait-closed

close-wakes-streams:
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport)
  client/att.Client? := null
  workers := []
  responder := task::
    fixture.status-reply transport fixture.create-command
    transport.received.add fixture.connection-event
    cccd transport 4 1
    cccd transport 9 2
  try:
    client = att.Client host (host.connect #[1, 2, 3, 4, 5, 6] --address-type=1)
    expect-throw "ATT_CLOSED":
      client.subscribe 3 --cccd=4: | data/att.Subscription |
        client.subscribe 8 --cccd=9 --indications: | changes/att.Subscription |
          ended := []
          [data, changes].do: | stream/att.Subscription |
            started := monitor.Latch
            done := monitor.Latch
            ended.add done
            workers.add (task::
              started.set true
              error := catch: stream.receive
              done.set error)
            started.get
          client.close
          ended.do: expect-equals "ATT_CLOSED" it.get
          expect-equals 0 client.queued-updates
  finally:
    workers.do: it.cancel
    responder.cancel
    if client: client.close
    host.close
    host.wait-closed

nested client/att.Client streams/List index/int [body]:
  if index == 8: return body.call
  return client.subscribe (index * 2 + 1) --cccd=(index * 2 + 2): | stream/att.Subscription |
    streams.add stream
    nested client streams (index + 1) body

shared-budget:
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport)
  client/att.Client? := null
  streams := []
  waiter/Task? := null
  responder := task::
    fixture.status-reply transport fixture.create-command
    transport.received.add fixture.connection-event
    8.repeat: cccd transport (it * 2 + 2) 1
    4.repeat: | index/int |
      8.repeat:
        bytes := #[0x1b, 0, 0, 0]
        bytes[1] = index * 2 + 1
        bytes[3] = index
        wire.incoming transport bytes
      // Drain the link inbox between bursts; the update budget remains full.
      barrier transport
    wire.outgoing transport #[0x0a, 1, 0]
    wire.incoming transport #[0x1d, 9, 0, 5]
    wire.outgoing transport #[0x1e]
    wire.incoming transport #[0x0b, 7]
    wire.outgoing transport #[0x0a, 1, 0]
    wire.incoming transport #[0x1b, 11, 0, 6]
    wire.incoming transport #[0x0b, 7]
    8.repeat: cccd transport (16 - it * 2) 0
    cccd transport 2 1
    cccd transport 2 0
  try:
    client = att.Client host (host.connect #[1, 2, 3, 4, 5, 6] --address-type=1)
    nested client streams 0:
      expect-throw "ATT_SUBSCRIPTION_LIMIT": client.subscribe 17 --cccd=18: unreachable
      4.repeat: expect-equals #[7] (client.read 1)
      started := monitor.Latch
      overflowed := monitor.Latch
      waiter = task::
        started.set true
        error := catch: streams[4].receive
        overflowed.set error
      started.get
      expect-equals #[7] (client.read 1)
      expect-equals "ATT_NOTIFICATION_OVERFLOW" overflowed.get
      expect-equals 32 client.queued-updates
      expect-equals 1 streams[4].dropped
      expect-throw "ATT_NOTIFICATION_OVERFLOW": streams[4].receive
      expect-equals #[0] streams[0].receive
      expect-equals #[7] (client.read 1)
      expect-equals 32 client.queued-updates
      expect-equals #[6] streams[5].receive
      expect-equals 0 streams[5].dropped
    expect-equals 0 client.queued-updates
    streams.do: | stream/att.Subscription |
      if stream.dropped == 0:
        expect-throw "ATT_SUBSCRIPTION_CLOSED": stream.receive
    client.subscribe 1 --cccd=2: null
    expect-equals 0 client.queued-updates
  finally:
    if waiter: waiter.cancel
    responder.cancel
    if client: client.close
    host.close
    host.wait-closed
