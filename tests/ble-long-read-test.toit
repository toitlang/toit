// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.att
import ble.experimental.attribute-server as server
import ble.experimental.central
import ble.experimental.hci
import expect show *
import io
import system
import .ble-fixture as fixture

main:
  server-tests
  with-timeout --ms=10_000: client-tests

server-tests:
  expect-throw "INVALID_ARGUMENT": server.Database --value-limit=513
  database := server.Database --value-limit=512
  database.add-service #[0xf0, 0xff]
  database.add-characteristic #[0xf1, 0xff] --read --notify
  session := database.session
  [0, 20, 22, 23, 44, 512].do: | length/int |
    value := payload length
    database.set-value 3 value
    expect-equals (#[0x0b] + value[0..(min length 22)]) (session.request #[0x0a, 3, 0])
    for offset := 0; offset <= length; offset++:
      expected := value[offset..(min length (offset + 22))]
      expect-equals (#[0x0d] + expected) (session.request (blob-request offset))
    expect-equals #[1, 0x0c, 3, 0, 7] (session.request (blob-request (length + 1)))
  expect-throw "INVALID_ARGUMENT": database.set-value 3 (ByteArray 513)
  expect-equals #[1, 0x0c, 0, 0, 4] (session.request #[0x0c, 3, 0])
  expect-equals #[1, 0x0c, 9, 0, 1] (session.request #[0x0c, 9, 0, 0, 0])
  session.request #[0x12, 4, 0, 1, 0]
  expect-equals (#[0x1b, 3, 0] + (payload 20)) (session.notification 3)
  limited := server.Database --value-limit=4
  limited.add-service #[0xf0, 0xff]
  limited.add-characteristic #[0xf1, 0xff] --read --write --value=#[7]
  expect-equals #[1, 0x12, 3, 0, 0x0d] (limited.session.request #[0x12, 3, 0, 1, 2, 3, 4, 5])
  expect-equals #[7] (limited.value 3)
  dynamic := server.Database --value-limit=512
  dynamic.add-service #[0xf0, 0xff]
  dynamic.add-characteristic #[0xf1, 0xff] --read --dynamic-read
  response := dynamic.session.request (blob-request 500): | request/server.ReadRequest |
    request.reply (payload 512)
  expect-equals (#[0x0d] + (payload 512)[500..]) response
  session.close

client-tests:
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport)
  responder := task::
    fixture.status-reply transport fixture.create-command
    transport.received.add fixture.connection-event
    [0, 22, 23, 44, 512].do: | length/int |
      value := payload length
      fixture.gatt-reply transport #[0x0a, 3, 0] (#[0x0b] + value[0..(min length 22)])
      for offset := 22; offset <= length; offset += 22:
        system.process-stats --gc
        fixture.gatt-reply transport (blob-request offset) (#[0x0d] + value[offset..(min length (offset + 22))])
    // Independent peers can end a fixed 22-byte value with Attribute Not Long.
    fixture.gatt-reply transport #[0x0a, 3, 0] (#[0x0b] + (payload 22))
    fixture.gatt-reply transport (blob-request 22) #[1, 0x0c, 3, 0, 0x0b]
    fixture.gatt-reply transport #[0x0a, 3, 0] (#[0x0b] + (payload 22))
    fixture.gatt-reply transport (blob-request 22) #[1, 0x0c, 3, 0, 7]
    // Security failures must propagate rather than returning a partial value.
    fixture.gatt-reply transport #[0x0a, 3, 0] (#[0x0b] + (payload 22))
    fixture.gatt-reply transport (blob-request 22) #[1, 0x0c, 3, 0, 5]
    // A limit error must leave the next ordinary request usable.
    fixture.gatt-reply transport #[0x0a, 3, 0] (#[0x0b] + (payload 22))
    fixture.gatt-reply transport #[0x0a, 3, 0] #[0x0b, 7]
  client/att.Client? := null
  try:
    link := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    client = att.Client host link
    retained := []
    [0, 22, 23, 44, 512].do: | length/int |
      value := client.read-long 3
      expect-equals (payload length) value
      retained.add [length, value]
    system.process-stats --gc
    retained.do: | item/List | expect-equals (payload item[0]) item[1]
    expect-equals (payload 22) (client.read-long 3)
    expect-equals (payload 22) (client.read-long 3)
    error := catch: client.read-long 3
    expect (error is att.AttributeError and error.code == 5)
    expect-throw "ATT_VALUE_TOO_LONG": client.read-long 3 --limit=21
    expect-equals #[7] (client.read 3)
  finally:
    if client: client.close
    host.close
    host.wait-closed
    responder.cancel

blob-request offset/int -> ByteArray:
  result := #[0x0c, 3, 0, 0, 0]
  io.LITTLE-ENDIAN.put-uint16 result 3 offset
  return result

payload length/int -> ByteArray:
  return ByteArray length: it % 251
