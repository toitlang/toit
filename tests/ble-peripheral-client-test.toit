// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// A GATT client on a peripheral-role link, sharing the bearer with the
// GATT server (Core 6.3 Vol 3 Part F 3.2.11): the central's own requests
// are served while a client request waits, responses and notifications reach
// the client, and both roles use one MTU.

import ble.experimental.att
import ble.experimental.attribute-server as attributes
import ble.experimental.central
import ble.experimental.gatt
import ble.experimental.gatt-server
import ble.experimental.hci
import expect show *
import monitor
import .ble-fixture as fixture
import .ble-peripheral-test as peripheral

main:
  with-timeout --ms=10_000:
    run --peer-exchanges
    run --no-peer-exchanges

/**
The central's database: GAP (its name is "Phone") and a battery service
  whose level notifies.
*/
class Peer:
  database/attributes.Database
  session/attributes.Session
  level/int

  constructor:
    database = attributes.Database.with-defaults --name="Phone" --mtu-limit=65
    database.add-service #[0x0f, 0x18]
    level = database.add-characteristic #[0x19, 0x2a] --read --notify --value=#[77]
    session = database.session

  /** Answers the next request our client sends, and returns it. */
  answer radio/fixture.FakeTransport -> ByteArray:
    request := take radio
    response := session.request request
    radio.received.add (fixture.att-event response)
    session.response-sent
    return request

/** Takes the next ATT PDU the host sends, acknowledging its packet. */
take radio/fixture.FakeTransport -> ByteArray:
  packet := radio.sent.take
  expect-equals #[2, 0x34, 2] packet[..3]
  expect-equals 4 packet[7]
  radio.received.add #[4, 0x13, 5, 1, 0x34, 2, 1, 0]
  return packet[9..]

run --peer-exchanges/bool:
  radio := fixture.FakeTransport
  radio.auto-disconnect = true
  host := central.Central (hci.Controller radio)
  database := attributes.Database.with-defaults --mtu-limit=65
  peer := Peer
  served := monitor.Latch
  client-ready := monitor.Latch
  checked := monitor.Latch
  responder := task::
    peripheral.setup radio
    event := fixture.connection-event.copy
    event[7] = 1
    radio.received.add event
    peripheral.reply radio 0x200a #[0]
    // A stray response before any client exists is dropped, not answered:
    // the next PDU sent is the answer to the central's read.
    radio.received.add (fixture.att-event #[0x0b, 1])
    radio.received.add (fixture.att-event #[0x0a, 3, 0])
    expect-equals #[0x0b] + "Toit".to-byte-array (take radio)
    if peer-exchanges:
      radio.received.add (fixture.att-event #[2, 50, 0])
      expect-equals #[3, 65, 0] (take radio)
    served.set true
    client-ready.get
    if not peer-exchanges:
      // Our client exchanges; the central offers 50.
      expect-equals #[2, 65, 0] (take radio)
      radio.received.add (fixture.att-event #[3, 50, 0])
    // Our client reads the central's name. Before answering, the central
    // reads ours: the server serves it while the client waits.
    expect-equals #[0x0a, 3, 0] (take radio)
    radio.received.add (fixture.att-event #[0x0a, 3, 0])
    expect-equals #[0x0b] + "Toit".to-byte-array (take radio)
    radio.received.add (fixture.att-event #[0x0b] + "Phone".to-byte-array)
    // Discovery of the battery service and its characteristic.
    while true:
      request := peer.answer radio
      // Subscribing: the CCCD write, then a notification of 78.
      if request[0] == 0x12 and request[3] == 1:
        radio.received.add (fixture.att-event (peer.session.notification peer.level))
        break
    peer.database.set-value peer.level #[78]
    radio.received.add (fixture.att-event (peer.session.notification peer.level))
    // The scope's disable.
    expect-equals #[0x12, peer.level + 1, 0, 0, 0] (peer.answer radio)
    checked.get
  server/gatt-server.Server? := null
  serving/Task? := null
  try:
    link := host.accept #[2, 1, 6]
    server = gatt-server.Server host link database
    serving = task:: catch: server.serve: | handle value | null
    served.get
    if peer-exchanges:
      while server.mtu != 50: sleep --ms=1
    client := server.client
    client-ready.set true
    expect-equals 50 client.exchange-mtu
    expect-equals 50 client.mtu
    expect-equals 50 server.mtu
    expect-equals "Phone".to-byte-array (client.read 3)
    services := gatt.services client
    battery := services.last
    expect-equals #[0x0f, 0x18] battery.uuid
    characteristic := (gatt.characteristics client battery).first
    values := []
    client.subscribe characteristic.handle --cccd=characteristic.handle + 1: | stream/att.Subscription |
      values.add stream.receive
      values.add stream.receive
    expect-equals [#[77], #[78]] values
    checked.set true
  finally:
    if server: server.close
    if serving: serving.cancel
    responder.cancel
    host.close
