// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// GATT client procedures against the host's own attribute server: included
// services (scripted, since the server declares none), read by UUID and Read
// Multiple in both forms, and the server's refusal of an unreadable handle.

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
    service := database.add-service #[0xf0, 0xff]
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
        wire.incoming transport (scripted request or (session.request request))
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
      services := gatt.services client
      primary := services.last
      expect-equals service primary.start
      included := gatt.included-services client primary
      expect-equals 2 included.size
      expect-equals [20, 25, BATTERY] [included[0].start, included[0].end, included[0].uuid]
      expect-equals [30, 31, CUSTOM] [included[1].start, included[1].end, included[1].uuid]
      expect-equals 20 included[0].service.start
    finally:
      if client: client.close
      responder.cancel
      host.close

/**
Answers what the reference server cannot: include declarations at handles 11
  and 12 of the fff0 service, and the declaration of the 128-bit one.
*/
scripted request/ByteArray -> ByteArray?:
  if request.size == 7 and request[0] == 8 and request[5..] == #[2, 0x28]:
    start := request[1] | (request[2] << 8)
    if start <= 11: return #[9, 8, 11, 0, 20, 0, 25, 0, 0x0f, 0x18]
    if start <= 12: return #[9, 6, 12, 0, 30, 0, 31, 0]
    return #[1, 8, request[1], request[2], 0x0a]
  if request == #[0x0a, 30, 0]: return #[0x0b] + CUSTOM
  return null
