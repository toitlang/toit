// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// GATT client procedures against the host's own attribute server: included
// services (secondary services with 16-bit and 128-bit UUIDs), read by UUID
// and Read Multiple in both forms, and the server's refusal of an unreadable
// handle.

import ble.experimental.att
import ble.experimental.attribute-server as attributes
import ble.experimental.central
import ble.experimental.gatt
import ble.experimental.hci
import expect show *
import .ble-fixture as fixture
import .ble-mtu-server-test as wire

BATTERY ::= #[0x0f, 0x18]
CUSTOM ::= ByteArray 16: it + 1

main:
  with-timeout --ms=10_000:
    transport := fixture.FakeTransport
    host := central.Central (hci.Controller transport)
    database := attributes.Database.with-defaults --value-limit=512
    battery := database.add-service BATTERY --secondary
    database.add-characteristic #[0x19, 0x2a] --read --value=#[90]
    custom := database.add-service CUSTOM --secondary
    service := database.add-service #[0xf0, 0xff]
    database.include-service battery
    database.include-service custom
    first := database.add-characteristic #[0xf1, 0xff] --read --value=#[1, 2]
    second := database.add-characteristic #[0xf2, 0xff] --read --value=#[3]
    hidden := database.add-characteristic #[0xf3, 0xff] --write
    again := database.add-characteristic #[0xf1, 0xff] --read --value=#[4, 5, 6]
    session := database.session
    responder := task::
      fixture.status-reply transport fixture.create-command
      transport.received.add fixture.connection-event
      while true:
        packet := transport.sent.take
        request := packet[9..]
        transport.received.add #[4, 0x13, 5, 1, 0x34, 2, 1, 0]
        wire.incoming transport (session.request request)
        session.response-sent
    client/att.Client? := null
    try:
      client = att.Client host (host.connect #[1, 2, 3, 4, 5, 6] --address-type=1)
      // Read Using Characteristic UUID finds both fff1 values.
      expect-equals [[first, #[1, 2]], [again, #[4, 5, 6]]] (gatt.read-by-uuid client #[0xf1, 0xff])
      expect-equals [[again, #[4, 5, 6]]] (gatt.read-by-uuid client #[0xf1, 0xff] --start=(first + 1))
      expect-equals [] (gatt.read-by-uuid client #[0xf9, 0xff])
      // Read Multiple concatenates, the variable form keeps the boundaries.
      expect-equals #[1, 2, 3] (gatt.read-multiple client [first, second])
      expect-equals [#[1, 2], #[3], #[4, 5, 6]] (gatt.read-multiple client [first, second, again] --variable)
      error := catch: gatt.read-multiple client [first, hidden]
      expect error is att.AttributeError
      expect-equals 2 error.code
      expect-equals hidden error.handle
      // Included services, one with a 16-bit and one with a 128-bit UUID.
      // Primary discovery does not find the secondary ones.
      services := gatt.services client
      expect-equals 3 services.size
      primary := services.last
      expect-equals service primary.start
      included := gatt.included-services client primary
      expect-equals 2 included.size
      expect-equals [battery, battery + 2, BATTERY] [included[0].start, included[0].end, included[0].uuid]
      expect-equals [custom, custom, CUSTOM] [included[1].start, included[1].end, included[1].uuid]
      expect-equals battery included[0].service.start
    finally:
      if client: client.close
      responder.cancel
      host.close
