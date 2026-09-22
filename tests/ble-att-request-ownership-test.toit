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
  with-timeout --ms=5_000:
    response-ownership
    queued-ownership

// A mutation after transmission must not exempt an ordinary read from the
// database-revision check used when its response arrives.
response-ownership:
  radio := fixture.FakeTransport
  host := central.Central (hci.Controller radio)
  client/att.Client? := null
  bytes := #[0x0a, 12, 0]
  responder := task::
    fixture.status-reply radio fixture.create-command
    radio.received.add fixture.connection-event
    fixture.gatt-reply radio #[0x12, 9, 0, 2, 0] #[0x13]
    wire.outgoing radio #[0x0a, 12, 0]
    bytes[0] = 2
    system.process-stats --gc
    wire.incoming radio #[0x1d, 8, 0, 1, 0, 0xff, 0xff]
    wire.outgoing radio #[0x1e]
    wire.incoming radio #[0x0b, 42]
    fixture.gatt-reply radio #[0x12, 9, 0, 0, 0] #[0x13]
    fixture.gatt-reply radio #[0x0a, 12, 0] #[0x0b, 43]
  try:
    client = att.Client host (host.connect #[1, 2, 3, 4, 5, 6] --address-type=1)
    client.monitor-service-changed 8 --cccd=9:
      expect-throw "GATT_DATABASE_CHANGED": client.request bytes --response=0x0b
    expect-equals #[43] (client.read 12)
    expect (not radio.closed)
  finally:
    responder.cancel
    if client: client.close
    host.close
    host.wait-closed

// Hold a first request while a second queues. The queued call must transmit
// its original value and opcode even when the caller overwrites every byte.
queued-ownership:
  radio := fixture.FakeTransport
  host := central.Central (hci.Controller radio)
  client/att.Client? := null
  bytes := #[0x12, 12, 0, 42]
  holding := monitor.Latch
  queued := monitor.Latch
  first := monitor.Latch
  second := monitor.Latch
  workers := []
  responder := task::
    fixture.status-reply radio fixture.create-command
    radio.received.add fixture.connection-event
    wire.outgoing radio #[0x0a, 12, 0]
    holding.set true
    queued.get
    bytes.fill 0
    system.process-stats --gc
    wire.incoming radio #[0x0b, 41]
    fixture.gatt-reply radio #[0x12, 12, 0, 42] #[0x13]
    fixture.gatt-reply radio #[0x0a, 12, 0] #[0x0b, 42]
  try:
    client = att.Client host (host.connect #[1, 2, 3, 4, 5, 6] --address-type=1)
    workers.add (task:: first.set (client.read 12))
    holding.get
    workers.add (task::
      queued.set true
      second.set (client.request bytes --response=0x13))
    expect-equals #[41] first.get
    expect-equals #[0x13] second.get
    expect-equals #[42] (client.read 12)
    expect-equals #[0, 0, 0, 0] bytes
    expect (not radio.closed)
  finally:
    workers.do: it.cancel
    responder.cancel
    if client: client.close
    host.close
    host.wait-closed
