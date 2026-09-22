// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.att
import ble.experimental.attribute-server as attributes
import ble.experimental.central
import ble.experimental.gatt
import ble.experimental.hci
import expect show *
import monitor
import system
import .ble-fixture as fixture
import .ble-mtu-server-test as wire

main:
  with-timeout --ms=15_000:
    tracked-records
    stale-subscription
    malformed-change #[0x1d, 8, 0, 0, 0, 1, 0]
    malformed-change #[0x1d, 8, 0, 2, 0, 1, 0]
    malformed-change #[0x1d, 8, 0, 1]

// The reference ATT database handles discovery; this fixture changes the database
// revision at deliberately awkward transaction boundaries.
tracked-records:
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport)
  database := attributes.Database.with-defaults --value-limit=512
  database.add-service #[0xf0, 0xff]
  database.add-characteristic #[0xf1, 0xff] --read --write --value=#[7]
  session := database.session
  client/att.Client? := null
  inject := 0
  inject-opcode/int? := null
  commits := 0
  cancels := 0
  confirmations := 0
  hold/monitor.Latch? := null
  holding := monitor.Latch
  workers := []
  responder := task::
    fixture.status-reply transport fixture.create-command
    transport.received.add fixture.connection-event
    while true:
      packet := transport.sent.take
      expect-equals 2 packet[0]
      request := packet[9..]
      transport.received.add #[4, 0x13, 5, 1, 0x34, 2, 1, 0]
      response := session.request request
      if request == #[0x18, 1]: commits++
      if request == #[0x18, 0]: cancels++
      if request == #[0x12, 9, 0, 2, 0]:
        // A legal early indication must not make CCCD enable fail.
        wire.incoming transport #[0x1d, 8, 0, 1, 0, 0xff, 0xff]
        wire.outgoing transport #[0x1e]
        confirmations++
      gate := hold
      if gate:
        hold = null
        holding.set true
        gate.get
      if inject > 0 and (inject-opcode == null or request[0] == inject-opcode):
        inject-opcode = null
        count := inject
        inject = 0
        count.repeat:
          wire.incoming transport #[0x1d, 8, 0, 10, 0, 12, 0]
          wire.outgoing transport #[0x1e]
          confirmations++
      if response:
        wire.incoming transport response
        session.response-sent
  try:
    client = att.Client host (host.connect #[1, 2, 3, 4, 5, 6] --address-type=1)
    before/gatt.Service := (gatt.services client).last
    retained/gatt.Characteristic? := null
    answer := gatt.with-service-changed client:
      expect (not before.valid)
      service/gatt.Service := (gatt.services client).last
      characteristic/gatt.Characteristic := (gatt.characteristics client service).first
      expect service.valid
      expect characteristic.valid
      expect-equals #[7] (gatt.read client characteristic)
      inject = 40
      expect-throw "GATT_DATABASE_CHANGED": gatt.read client characteristic
      expect-equals 41 confirmations
      expect-equals 0 client.queued-updates
      expect-equals 0 client.dropped-notifications
      expect (not service.valid)
      expect (not characteristic.valid)
      sent := transport.sent-count
      expect-throw "GATT_DATABASE_CHANGED": gatt.characteristics client service
      expect-throw "GATT_DATABASE_CHANGED": gatt.descriptors client characteristic
      expect-throw "GATT_DATABASE_CHANGED": gatt.read client characteristic
      expect-throw "GATT_DATABASE_CHANGED": gatt.write client characteristic #[9]
      expect-throw "GATT_DATABASE_CHANGED": gatt.read-long client characteristic
      expect-throw "GATT_DATABASE_CHANGED": gatt.write-long client characteristic #[9]
      expect-equals sent transport.sent-count
      system.process-stats --gc
      service = (gatt.services client).last
      retained = (gatt.characteristics client service).first
      expect-equals #[7] (gatt.read client retained)
      // A checked long write waits behind a read and must recheck its
      // revision before sending, rather than using a now-stale numeric handle.
      gate := monitor.Latch
      hold = gate
      inject = 1
      first := monitor.Latch
      second := monitor.Latch
      started := monitor.Latch
      workers.add (task::
        error := catch: gatt.read client retained
        first.set error)
      holding.get
      workers.add (task::
        started.set true
        error := catch: gatt.write-long client retained #[9]
        second.set error)
      started.get
      sent = transport.sent-count
      gate.set true
      expect-equals "GATT_DATABASE_CHANGED" first.get
      expect-equals "GATT_DATABASE_CHANGED" second.get
      expect-equals (sent + 1) transport.sent-count  // Only the confirmation.
      // An indication while discovering prevents publishing mixed revisions.
      inject = 1
      expect-throw "GATT_DATABASE_CHANGED": gatt.services client
      service = (gatt.services client).last
      retained = (gatt.characteristics client service).first
      database.set-value 12 (wire.payload 40)
      expect-equals (wire.payload 40) (gatt.read-long client retained)
      inject = 1
      inject-opcode = 0x0c
      expect-throw "GATT_DATABASE_CHANGED": gatt.read-long client retained
      service = (gatt.services client).last
      retained = (gatt.characteristics client service).first
      inject = 1
      inject-opcode = 0x16
      expect-throw "GATT_DATABASE_CHANGED": gatt.write-long client retained (wire.payload 60)
      expect-equals 0 commits
      expect-equals 1 cancels
      expect-equals (wire.payload 40) (database.value 12)
      service = (gatt.services client).last
      retained = (gatt.characteristics client service).first
      gatt.write-long client retained (wire.payload 60)
      expect-equals 1 commits
      expect-equals (wire.payload 60) (gatt.read-long client retained)
      // Execute has already taken effect when the indication arrives. Report
      // invalidation without promising rollback or replaying the write.
      inject = 1
      inject-opcode = 0x18
      expect-throw "GATT_DATABASE_CHANGED": gatt.write-long client retained #[99]
      expect-equals 2 commits
      expect-equals 2 cancels
      expect-equals #[99] (database.value 12)
      service = (gatt.services client).last
      retained = (gatt.characteristics client service).first
      expect-equals #[99] (gatt.read-long client retained)
      42
    expect-equals 42 answer
    expect (not retained.valid)
    fresh/gatt.Service := (gatt.services client).last
    expect fresh.valid
    client.close
    expect (not fresh.valid)
  finally:
    workers.do: it.cancel
    responder.cancel
    session.close
    if client: client.close
    host.close
    host.wait-closed

malformed-change indication/ByteArray:
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport)
  client/att.Client? := null
  responder := task::
    fixture.status-reply transport fixture.create-command
    transport.received.add fixture.connection-event
    fixture.gatt-reply transport #[0x12, 9, 0, 2, 0] #[0x13]
    wire.outgoing transport #[0x0a, 12, 0]
    wire.incoming transport indication
    wire.outgoing transport #[0x1e]
  try:
    client = att.Client host (host.connect #[1, 2, 3, 4, 5, 6] --address-type=1)
    expect-throw "GATT_INVALID_SERVICE_CHANGED":
      client.monitor-service-changed 8 --cccd=9:
        client.read 12
    client.wait-closed
  finally:
    responder.cancel
    if client: client.close
    host.close
    host.wait-closed

stale-subscription:
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport)
  client/att.Client? := null
  ended := monitor.Latch
  responder := task::
    fixture.status-reply transport fixture.create-command
    transport.received.add fixture.connection-event
    fixture.gatt-reply transport #[0x12, 9, 0, 2, 0] #[0x13]
    fixture.gatt-reply transport #[0x12, 13, 0, 1, 0] #[0x13]
    wire.outgoing transport #[0x0a, 12, 0]
    wire.incoming transport #[0x1d, 8, 0, 10, 0, 13, 0]
    wire.outgoing transport #[0x1e]
    wire.incoming transport #[0x0b, 7]
    ended.set transport.sent-count
  try:
    client = att.Client host (host.connect #[1, 2, 3, 4, 5, 6] --address-type=1)
    // Unwinding both CCCD scopes preserves the specific invalidation while
    // still closing the link whose descriptor handles became stale.
    expect-throw "GATT_DATABASE_CHANGED":
      client.monitor-service-changed 8 --cccd=9:
        client.subscribe 12 --cccd=13: | stream/att.Subscription |
          expect-throw "GATT_DATABASE_CHANGED": client.read 12
          expect-throw "GATT_DATABASE_CHANGED": stream.receive
    expect-equals ended.get transport.sent-count
    expect-equals 0 client.queued-updates
    client.wait-closed
  finally:
    responder.cancel
    if client: client.close
    host.close
    host.wait-closed
