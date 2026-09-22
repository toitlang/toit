// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.attribute-server as attributes
import ble.experimental.central
import ble.experimental.gatt-server
import ble.experimental.hci
import expect show *
import io
import system
import .ble-fixture as fixture
import .ble-peripheral-test as peripheral

main:
  session-tests
  with-timeout --ms=10_000: fragmented-server
  with-timeout --ms=5_000: fragmented-server --receive-limit=65
  with-timeout --ms=10_000:
    [247, 517].do: | limit/int |
      [23, 512].do: | peer/int |
        server-configuration limit peer
    [23, 247].do: | peer/int |
      server-configuration 517 peer --descriptor

// GATT/SR/GAC/BV-01-C: both prescribed tester MTUs on a fresh LE connection.
server-configuration limit/int peer/int --descriptor/bool=false:
  database := attributes.Database --value-limit=512 --mtu-limit=limit
  database.add-service #[0xf0, 0xff]
  value := database.add-characteristic #[0xf1, 0xff] --read --value=(payload 512)
  descriptor-handle := descriptor
      ? (database.add-descriptor value #[0xf2, 0xff] --value=(payload 512))
      : 0
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport) --receive-limit=517
  negotiated := min limit peer
  responder := task::
    peripheral.setup transport
    event := fixture.connection-event.copy
    event[7] = 1
    transport.received.add event
    peripheral.reply transport 0x200a #[0]
    incoming transport (exchange 2 peer)
    outgoing transport (exchange 3 limit)
    incoming transport #[0x0a, 3, 0]
    outgoing transport (#[0x0b] + (payload (negotiated - 1)))
    if descriptor:
      expect-equals 4 descriptor-handle
      // Discover the descriptor before the prescribed Read Blob sequence.
      incoming transport #[4, 4, 0, 4, 0]
      outgoing transport #[5, 1, 4, 0, 0xf2, 0xff]
      retained := payload 512
      for offset := 0; offset < retained.size; offset += negotiated - 1:
        request := #[0x0c, 4, 0, 0, 0]
        io.LITTLE-ENDIAN.put-uint16 request 3 offset
        incoming transport request
        outgoing transport (#[0x0d] + retained[offset..min retained.size (offset + negotiated - 1)])
        system.process-stats --gc
        expect-equals (payload 512) retained
      // GATT/SR/GAR/BV-08-C: offset exactly at the end yields an empty blob.
      incoming transport #[0x0c, 4, 0, 0, 2]
      outgoing transport #[0x0d]
      // A subsequent read proves the same bearer remains usable.
      incoming transport #[0x0a, 3, 0]
      outgoing transport (#[0x0b] + (payload (negotiated - 1)))
    transport.received.add #[4, 5, 4, 0, 0x34, 2, 0x13]
  try:
    link := host.accept #[2, 1, 6]
    server := gatt-server.Server host link database
    expect-equals 23 server.mtu
    server.serve: | handle/int value/ByteArray |
      throw "UNEXPECTED_WRITE_DURING_MTU_CONFIGURATION"
    expect-equals negotiated server.mtu
  finally:
    responder.cancel
    host.close
    host.wait-closed

session-tests:
  [23, 64, 247, 517].do: | limit/int |
    database := attributes.Database --value-limit=512 --mtu-limit=limit
    database.add-service #[0xf0, 0xff]
    database.add-characteristic #[0xf1, 0xff] --read --write --notify --value=(payload 512)
    session := database.session
    expect-equals 23 session.mtu
    expect-equals (exchange 3 limit) (session.request (exchange 2 517))
    expect-equals 23 session.mtu
    session.response-sent
    expect-equals limit session.mtu
    expect-equals (#[0x0b] + (payload (min 512 (limit - 1)))) (session.request #[0x0a, 3, 0])
    session.request #[0x12, 4, 0, 1, 0]
    expect-equals (#[0x1b, 3, 0] + (payload (min 512 (limit - 3)))) (session.notification 3)
    page := session.request #[8, 3, 0, 3, 0, 0xf1, 0xff]
    width := min 255 (limit - 2)
    expect-equals width page[1]
    expect-equals (2 + width) page.size
    expect-equals (payload (width - 2)) page[4..]
    expect-equals #[1, 0x12, 0, 0, 4] (session.request (#[0x12] + (ByteArray limit)))
    // Every new session starts at the default, irrespective of this session.
    expect-equals 23 database.session.mtu
    session.close
  database := attributes.Database --value-limit=512 --mtu-limit=517
  database.add-service #[0xf0, 0xff]
  database.add-characteristic #[0xf1, 0xff] --write
  session := database.session
  expect-equals (exchange 3 517) (session.request (exchange 2 247))
  session.response-sent
  expect-equals 247 session.mtu
  expect-equals (exchange 3 517) (session.request (exchange 2 22))
  session.response-sent
  expect-equals 23 session.mtu
  session.request (exchange 2 517)
  session.response-sent
  expect-equals #[1, 0x12, 3, 0, 0x0d] (session.request (#[0x12, 3, 0] + (ByteArray 514)))
  // Larger PDUs must not multiply the prepared-data budget.
  prepare := #[0x16, 3, 0, 0, 0] + (payload 512)
  expect-equals (#[0x17] + prepare[1..]) (session.request prepare)
  expect-equals #[1, 0x16, 3, 0, 9] (session.request prepare)
  expect-equals #[0x19] (session.request #[0x18, 0])
  expect-equals (#[0x17] + prepare[1..]) (session.request prepare)
  session.close
  strict-db := attributes.Database --value-limit=512 --mtu-limit=517
  strict-db.add-service #[0xf0, 0xff]
  strict-db.add-characteristic #[0xf1, 0xff] --notify --value=(payload 21)
  strict := strict-db.session
  expect-equals null (strict.notification 3 --no-truncate)
  strict.request #[0x12, 4, 0, 1, 0]
  expect-throw "GATT_VALUE_EXCEEDS_MTU": strict.notification 3 --no-truncate
  strict-db.set-value 3 (payload 20)
  expect-equals (#[0x1b, 3, 0] + (payload 20)) (strict.notification 3 --no-truncate)
  strict.request (exchange 2 247)
  strict.response-sent
  strict-db.set-value 3 (payload 244)
  expect-equals 247 (strict.notification 3 --no-truncate).size
  strict-db.set-value 3 (payload 245)
  expect-throw "GATT_VALUE_EXCEEDS_MTU": strict.notification 3 --no-truncate
  // The direct API's explicit truncating mode remains available.
  expect-equals 247 (strict.notification 3).size
  strict.close
  expect-throw "INVALID_ARGUMENT": attributes.Database --mtu-limit=518
  expect-throw "INVALID_ARGUMENT": attributes.Database --mtu-limit=22

fragmented-server --receive-limit/int=517:
  database := attributes.Database --value-limit=512 --mtu-limit=517
  database.add-service #[0xf0, 0xff]
  database.add-characteristic #[0xf1, 0xff] --read --write --value=(payload 512)
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport) --receive-limit=receive-limit
  responder := task::
    fixture.status-reply transport fixture.create-command
    transport.received.add fixture.connection-event
    transport.received.add (fixture.att-event (exchange 2 517))
    outgoing transport (exchange 3 517)
    incoming transport (#[0x12, 3, 0] + (payload 512))
    outgoing transport #[0x13]
    transport.received.add (fixture.att-event #[0x0a, 3, 0])
    outgoing transport (#[0x0b] + (payload 512))
    transport.received.add #[4, 5, 4, 0, 0x34, 2, 0x13]
  try:
    link := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    expect-equals receive-limit link.receive-limit
    if receive-limit < 517:
      expect-throw "GATT_MTU_EXCEEDS_LINK_LIMIT": gatt-server.Server host link database
      link.claim-receive "constructor did not claim the stream"
      return
    server := gatt-server.Server host link database
    server.serve: | handle/int value/ByteArray | expect-equals (payload 512) value
    expect-equals 517 server.mtu
  finally:
    responder.cancel
    host.close
    host.wait-closed

exchange opcode/int mtu/int -> ByteArray:
  result := #[opcode, 0, 0]
  io.LITTLE-ENDIAN.put-uint16 result 1 mtu
  return result

incoming transport/fixture.FakeTransport bytes/ByteArray -> none:
  pdu := #[0, 0, 4, 0] + bytes
  io.LITTLE-ENDIAN.put-uint16 pdu 0 bytes.size
  offset := 0
  while offset < pdu.size:
    length := min 27 (pdu.size - offset)
    transport.received.add (fixture.incoming-acl pdu[offset..offset + length] --start=(offset == 0))
    offset += length

outgoing transport/fixture.FakeTransport bytes/ByteArray -> none:
  pdu := #[0, 0, 4, 0] + bytes
  io.LITTLE-ENDIAN.put-uint16 pdu 0 bytes.size
  offset := 0
  while offset < pdu.size:
    packet := transport.sent.take
    expect-equals 2 packet[0]
    expect-equals (offset == 0 ? 0x0234 : 0x1234) (io.LITTLE-ENDIAN.uint16 packet 1)
    length := io.LITTLE-ENDIAN.uint16 packet 3
    expect (1 <= length <= 27 and packet.size == 5 + length)
    expect-equals pdu[offset..offset + length] packet[5..]
    offset += length
    system.process-stats --gc
    transport.received.add #[4, 0x13, 5, 1, 0x34, 2, 1, 0]

payload length/int -> ByteArray:
  return ByteArray length: it % 251
