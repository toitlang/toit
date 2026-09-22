// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.attribute-server as attributes
import ble.experimental.central
import ble.experimental.gatt-server
import ble.experimental.hci
import expect show *
import monitor
import .ble-fixture as fixture
import .ble-mtu-server-test as wire

main:
  with-timeout --ms=10_000:
    configuration
    ["confirmed", "timeout", "disconnect", "malformed"].do: connected it

configuration:
  [false, true].do: | notify/bool |
    database := attributes.Database --value-limit=512 --mtu-limit=517
    database.add-service #[0xf0, 0xff]
    value := database.add-characteristic #[0xf1, 0xff] --indicate --notify=notify --value=(wire.payload 512)
    session := database.session
    expect-equals null (session.indication value)
    expect-equals #[0x13] (session.request #[0x12, 4, 0, 2, 0])
    expect-equals #[0x0b, 2, 0] (session.request #[0x0a, 4, 0])
    expect (session.subscribed value --indications)
    expect (not (session.subscribed value))
    expect-equals (#[0x1d, 3, 0] + (wire.payload 20)) (session.indication value)
    expect-throw "GATT_VALUE_EXCEEDS_MTU": session.indication value --no-truncate
    session.request (wire.exchange 2 517)
    session.response-sent
    retained := session.indication value
    database.set-value value #[9]
    expect-equals (#[0x1d, 3, 0] + (wire.payload 512)) retained
    expect-equals (notify ? #[0x13] : #[1, 0x12, 4, 0, 0x13])
        session.request #[0x12, 4, 0, 3, 0]
    if notify:
      expect-equals #[0x1b, 3, 0, 9] (session.notification value)
    // Invalid prepared CCCD changes leave the prior configuration intact.
    session.request #[0x16, 4, 0, 0, 0, 4, 0]
    expect-equals #[1, 0x18, 4, 0, 0x13] (session.request #[0x18, 1])
    expect-equals (notify ? #[0x0b, 3, 0] : #[0x0b, 2, 0])
        session.request #[0x0a, 4, 0]
    session.request #[0x16, 4, 0, 0, 0, 0, 0]
    expect-equals #[0x19] (session.request #[0x18, 1])
    expect-equals null (session.indication value)
    expect-equals null (database.session.indication value)
    session.close
    expect-throw "ATT_SERVER_CLOSED": session.indication value

connected mode/string:
  database := attributes.Database
  database.add-service #[0xf0, 0xff]
  database.add-characteristic #[0xf1, 0xff] --read --notify --indicate --value=#[7]
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport)
  server/gatt-server.Server? := null
  submitted := monitor.Latch
  outcome := monitor.Latch
  canceled-waiter := monitor.Latch
  waiter := task::
    receipt/gatt-server.Indication := submitted.get
    error := catch:
      if mode == "confirmed":
        started := monitor.Latch
        ended := monitor.Latch
        observer := task::
          try:
            started.set true
            receipt.wait
          finally:
            critical-do --no-respect-deadline: ended.set true
        started.get
        observer.cancel
        ended.get
        canceled-waiter.set true
      receipt.wait
      if mode == "confirmed":
        // Confirmation releases the slot; no per-value queue is accumulated.
        second := server.indicate 3
        second.wait
        receipt.wait
    outcome.set (error or "confirmed")
  responder := task::
    fixture.status-reply transport fixture.create-command
    transport.received.add fixture.connection-event
    // An unsolicited confirmation must not produce an Error Response.
    wire.incoming transport #[0x1e]
    wire.incoming transport #[0x12, 4, 0, 3, 0]
    wire.outgoing transport #[0x13]
    wire.outgoing transport #[0x1d, 3, 0, 7]
    wire.outgoing transport #[0x1b, 3, 0, 7]
    if mode == "timeout":
      sleep --ms=100
    else if mode == "malformed":
      wire.incoming transport #[0x1e, 0]
    else if mode == "confirmed":
      // Requests and notifications can proceed while confirmation is pending.
      wire.incoming transport #[0x0a, 3, 0]
      wire.outgoing transport #[0x0b, 7]
      canceled-waiter.get
      wire.incoming transport #[0x1e]
      wire.outgoing transport #[0x1d, 3, 0, 7]
      wire.incoming transport #[0x1e]
      expect-equals "confirmed" outcome.get
    if mode == "confirmed" or mode == "disconnect":
      transport.received.add #[4, 5, 4, 0, 0x34, 2, 0x13]
  try:
    link := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    server = gatt-server.Server host link database
    expect-throw "GATT_NOT_SERVING": server.indicate 3
    error := catch:
      server.serve: | handle/int value/ByteArray |
        expect-equals 4 handle
        receipt := server.indicate 3 --timeout=(Duration --ms=(mode == "timeout" ? 50 : 3_000))
        submitted.set receipt
        expect-throw "GATT_INDICATION_BUSY": server.indicate 3
        expect-throw "GATT_INDICATION_WAIT_IN_SERVE": receipt.wait
        expect (server.notify 3)
    expected := mode == "confirmed" ? "confirmed" : (mode == "timeout" ? "GATT_INDICATION_TIMEOUT" : "GATT_SERVER_CLOSED")
    expect-equals expected outcome.get
    if mode == "confirmed" or mode == "disconnect": expect-equals null error
    if mode == "malformed": expect-equals "ATT_INVALID_CONFIRMATION" error
    expect-throw "GATT_SERVER_CLOSED": server.indicate 3
  finally:
    waiter.cancel
    responder.cancel
    host.close
    host.wait-closed
