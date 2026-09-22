// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.att
import ble.experimental.central
import ble.experimental.hci
import expect show *
import io
import .ble-hci-test as fixture
import .ble-mtu-server-test as wire

main:
  with-timeout --ms=30_000:
    [[23, 517], [64, 517], [247, 517], [517, 247], [517, 517], [517, 22]].do:
      negotiated it[0] it[1]
    // GATT/CL/GAC/BV-01-C: tester RX MTU 512, long value exceeds our MTU.
    negotiated 247 512
    negotiated 517 247 --peer-first
    negotiated 517 247 --crossing
    failure "unsupported"
    failure "malformed"
    failure "mismatch"
    failure "timeout"
    growing-long-read

negotiated limit/int peer/int --peer-first/bool=false --crossing/bool=false:
  mtu := peer < 23 ? 23 : (min limit peer)
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport) --receive-limit=(max 65 limit)
  client/att.Client? := null
  responder := task::
    fixture.status-reply transport fixture.create-command
    transport.received.add fixture.connection-event
    if not peer-first: wire.outgoing transport (wire.exchange 2 limit)
    if peer-first or crossing:
      wire.incoming transport (wire.exchange 2 peer)
      wire.outgoing transport (wire.exchange 3 limit)
      if crossing:
        expect-equals 23 client.mtu
        wire.incoming transport #[0x0a, 3, 0]
        wire.outgoing transport #[1, 0x0a, 0, 0, 6]
    if not peer-first: wire.incoming transport (wire.exchange 3 peer)
    // Queue a full-sized PDU immediately after the response, before the caller
    // necessarily resumes. The ATT reader must already use the new limit.
    value := wire.payload (min 512 (mtu - 3))
    wire.incoming transport (#[0x1b, 3, 0] + value)
    wire.outgoing transport (#[0x12, 3, 0] + value)
    wire.incoming transport #[0x13]
    bytes := wire.payload 512
    offset := 0
    while offset < bytes.size:
      length := min (mtu - 5) (bytes.size - offset)
      packet := #[0x16, 3, 0, 0, 0] + bytes[offset..offset + length]
      io.LITTLE-ENDIAN.put-uint16 packet 3 offset
      wire.outgoing transport packet
      packet[0] = 0x17
      wire.incoming transport packet
      offset += length
    wire.outgoing transport #[0x18, 1]
    wire.incoming transport #[0x19]
    wire.outgoing transport #[0x0a, 3, 0]
    wire.incoming transport (#[0x0b] + bytes[0..(min 512 (mtu - 1))])
    for read-offset := mtu - 1; read-offset <= 512; read-offset += mtu - 1:
      packet := #[0x0c, 3, 0, 0, 0]
      io.LITTLE-ENDIAN.put-uint16 packet 3 read-offset
      wire.outgoing transport packet
      wire.incoming transport (#[0x0d] + bytes[read-offset..(min 512 (read-offset + mtu - 1))])
  try:
    link := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    expect-throw "INVALID_ARGUMENT": att.Client host link --mtu-limit=518
    if limit == 23:
      expect-throw "INVALID_ARGUMENT": att.Client host link --mtu-limit=517
    client = att.Client host link --mtu-limit=limit
    expect-equals 23 client.mtu
    notification/att.Notification? := null
    if peer-first: notification = client.receive-notification
    expect-equals mtu client.exchange-mtu
    expect-equals mtu client.exchange-mtu
    expect-throw "ATT_USE_EXCHANGE_MTU": client.request #[2, 23, 0] --response=3
    if not notification: notification = client.receive-notification
    value := wire.payload (min 512 (mtu - 3))
    expect-equals value notification.value
    client.write 3 value
    expect-throw "INVALID_ARGUMENT": client.write 3 (ByteArray (value.size + 1))
    client.write-long 3 (wire.payload 512)
    expect-equals (wire.payload 512) (client.read-long 3)
  finally:
    responder.cancel
    if client: client.close
    host.close
    host.wait-closed

failure kind/string:
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport) --receive-limit=517
  responder := task::
    fixture.status-reply transport fixture.create-command
    transport.received.add fixture.connection-event
    wire.outgoing transport (wire.exchange 2 517)
    if kind == "unsupported":
      wire.incoming transport #[1, 2, 0, 0, 6]
      wire.outgoing transport #[0x0a, 3, 0]
      wire.incoming transport #[0x0b, 7]
    else if kind == "malformed":
      wire.incoming transport #[3, 64]
    else if kind == "mismatch":
      wire.incoming transport (wire.exchange 2 64)
      wire.outgoing transport (wire.exchange 3 517)
      wire.incoming transport (wire.exchange 3 247)
  client/att.Client? := null
  try:
    link := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    client = att.Client host link --mtu-limit=517
    if kind == "unsupported":
      expect-equals 23 client.exchange-mtu
      expect-equals 23 client.exchange-mtu
      expect-equals #[7] (client.read 3)
    else if kind == "malformed":
      expect-throw "ATT_MALFORMED_RESPONSE": client.exchange-mtu
      expect (not link.connected)
    else if kind == "mismatch":
      expect-throw "ATT_MTU_CHANGED": client.exchange-mtu
      expect (not link.connected)
    else:
      expect-throw "DEADLINE_EXCEEDED": client.exchange-mtu --timeout=(Duration --ms=20)
      expect (not link.connected)
  finally:
    responder.cancel
    if client: client.close
    host.close
    host.wait-closed

growing-long-read:
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport) --receive-limit=517
  responder := task::
    fixture.status-reply transport fixture.create-command
    transport.received.add fixture.connection-event
    wire.outgoing transport #[0x0a, 3, 0]
    wire.incoming transport (#[0x0b] + (wire.payload 22))
    wire.outgoing transport #[0x0c, 3, 0, 22, 0]
    wire.incoming transport (wire.exchange 2 517)
    wire.outgoing transport (wire.exchange 3 517)
    // The fixed value now fits a normal read; a peer may reject Read Blob.
    wire.incoming transport #[1, 0x0c, 3, 0, 0x0b]
    wire.outgoing transport #[0x0a, 3, 0]
    wire.incoming transport (#[0x0b] + (wire.payload 512))
  client/att.Client? := null
  try:
    link := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    client = att.Client host link --mtu-limit=517
    expect-equals (wire.payload 512) (client.read-long 3)
    expect-equals 517 client.mtu
  finally:
    responder.cancel
    if client: client.close
    host.close
    host.wait-closed
