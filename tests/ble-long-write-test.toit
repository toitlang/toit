// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.att
import ble.experimental.attribute-server as server
import ble.experimental.central
import ble.experimental.hci
import expect show *
import io
import monitor
import system
import .ble-fixture as fixture

main:
  server-tests
  server-gap-recovery
  with-timeout --ms=10_000: client-tests
  with-timeout --ms=5_000: cancel-tests
  with-timeout --ms=5_000: serialization-tests

server-gap-recovery:
  // Exercise invalid-offset rollback across multiple attributes, including
  // a valid staged value before the gap. No write callback may escape.
  database := server.Database --value-limit=512
  database.add-service #[0xf0, 0xff]
  first := database.add-characteristic #[0xf1, 0xff] --read --write --value=#[7]
  second := database.add-characteristic #[0xf2, 0xff] --read --write --value=#[8]
  session := database.session
  try:
    [false, true].do: | cancel/bool |
      [[first, 0, 1], [second, 0, 2], [second, 10, 3]].do: | part/List |
        packet := #[0x16, part[0], 0, part[1], 0, part[2]]
        expected := packet.copy
        expected[0] = 0x17
        expect-equals expected (session.request packet)
        // Staging owns its input across caller mutation and compaction.
        packet[5] = 99
        system.process-stats --gc
      if cancel:
        expect-equals #[0x19] (session.request #[0x18, 0])
      else:
        expect-equals #[1, 0x18, second, 0, 7] (session.request #[0x18, 1])
      expect-equals #[7] (database.value first)
      expect-equals #[8] (database.value second)
      session.writes-do: | _ _ | unreachable
      // Both cancellation and failed execution discard every queued fragment.
      expect-equals #[0x19] (session.request #[0x18, 1])
      session.writes-do: | _ _ | unreachable
      expect-equals #[7] (database.value first)
      expect-equals #[8] (database.value second)
    // The same session can subsequently commit both values with no stale gap.
    [first, second].do: | handle/int |
      expect-equals #[0x17, handle, 0, 0, 0, 42]
          session.request #[0x16, handle, 0, 0, 0, 42]
    system.process-stats --gc
    expect-equals #[0x19] (session.request #[0x18, 1])
    expect-equals #[42] (database.value first)
    expect-equals #[42] (database.value second)
    accepted := {}
    session.writes-do: | handle/int value/ByteArray |
      expect-equals #[42] value
      expect (not (accepted.contains handle))
      accepted.add handle
    expect-equals {first, second} accepted
  finally:
    session.close

server-tests:
  database := server.Database --value-limit=512
  database.add-service #[0xf0, 0xff]
  database.add-characteristic #[0xf1, 0xff] --read --write --value=#[7]
  session := database.session
  bytes := payload 512
  packets bytes: | packet/ByteArray |
    expected := packet.copy
    expected[0] = 0x17
    expect-equals expected (session.request packet)
    expect-equals #[7] (database.value 3)
    system.process-stats --gc
  expect-equals #[1, 0x16, 3, 0, 9] (session.request (prepare #[] 0))
  expect-equals #[0x19] (session.request #[0x18, 1])
  expect-equals bytes (database.value 3)
  packets (payload 19): | packet/ByteArray | session.request packet
  expect-equals #[0x19] (session.request #[0x18, 0])
  expect-equals bytes (database.value 3)
  // Failure at execute clears the whole queue and leaves the old value intact.
  session.request (prepare #[1] 512)
  expect-equals #[1, 0x18, 3, 0, 0x0d] (session.request #[0x18, 1])
  expect-equals #[0x19] (session.request #[0x18, 1])
  expect-equals bytes (database.value 3)
  session.request (prepare #[] 0)
  expect-equals #[0x19] (session.request #[0x18, 1])
  expect-equals #[] (database.value 3)
  session.close

client-tests:
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport)
  shared := payload 512
  responder := task::
    fixture.status-reply transport fixture.create-command
    transport.received.add fixture.connection-event
    [0, 1, 18, 19, 512].do: | length/int |
      packets (payload length): | packet/ByteArray |
        fixture.att-sent transport packet
        // Mutating caller storage after submission must not change later parts.
        if length == 512: shared[511] = 0xff
        response := packet.copy
        response[0] = 0x17
        system.process-stats --gc
        transport.received.add (fixture.att-event response)
      fixture.gatt-reply transport #[0x18, 1] #[0x19]
    // The first part is accepted; queue-full on the second must trigger cancel.
    first := prepare (payload 18) 0
    response := first.copy
    response[0] = 0x17
    fixture.gatt-reply transport first response
    fixture.gatt-reply transport (prepare #[18] 18) #[1, 0x16, 3, 0, 9]
    fixture.gatt-reply transport #[0x18, 0] #[0x19]
    // A mismatched echo must also cancel, without committing.
    fixture.gatt-reply transport (prepare #[0] 0) #[0x17, 3, 0, 0, 0, 99]
    fixture.gatt-reply transport #[0x18, 0] #[0x19]
    fixture.gatt-reply transport #[0x0a, 3, 0] #[0x0b, 7]
  client/att.Client? := null
  try:
    link := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    client = att.Client host link
    [0, 1, 18, 19, 512].do: | length/int |
      client.write-long 3 (length == 512 ? shared : (payload length))
    error := catch: client.write-long 3 (payload 19)
    expect (error is att.AttributeError and error.code == 9)
    expect-throw "ATT_PREPARE_MISMATCH": client.write-long 3 #[0]
    expect-equals #[7] (client.read 3)
    expect-throw "INVALID_ARGUMENT": client.write-long 3 (ByteArray 513)
  finally:
    if client: client.close
    host.close
    host.wait-closed
    responder.cancel

cancel-tests:
  transport := fixture.FakeTransport
  transport.auto-disconnect = true
  host := central.Central (hci.Controller transport)
  waiting := monitor.Latch
  ended := monitor.Latch
  responder := task::
    fixture.status-reply transport fixture.create-command
    transport.received.add fixture.connection-event
    first := prepare (payload 18) 0
    response := first.copy
    response[0] = 0x17
    fixture.gatt-reply transport first response
    fixture.att-sent transport (prepare #[18] 18)
    waiting.set true
  client/att.Client? := null
  writer/Task? := null
  try:
    link := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    client = att.Client host link
    writer = task::
      try:
        client.write-long 3 (payload 19)
      finally:
        critical-do --no-respect-deadline: ended.set true
    waiting.get
    writer.cancel
    ended.get
    fixture.wait-ended link
    expect (not transport.closed)
    expect-throw "ATT_REQUEST_ABORTED": client.read 3
  finally:
    if writer: writer.cancel
    if client: client.close
    host.close
    host.wait-closed
    responder.cancel

serialization-tests:
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport)
  waiting := monitor.Latch
  release := monitor.Latch
  writer-ended := monitor.Latch
  reader-started := monitor.Latch
  reader-result := monitor.Latch
  responder := task::
    fixture.status-reply transport fixture.create-command
    transport.received.add fixture.connection-event
    first := prepare (payload 18) 0
    fixture.att-sent transport first
    waiting.set true
    release.get
    first[0] = 0x17
    transport.received.add (fixture.att-event first)
    second := prepare #[18] 18
    response := second.copy
    response[0] = 0x17
    fixture.gatt-reply transport second response
    fixture.gatt-reply transport #[0x18, 1] #[0x19]
    // An already-waiting read must appear only after Execute has completed.
    fixture.gatt-reply transport #[0x0a, 3, 0] #[0x0b, 7]
  client/att.Client? := null
  writer/Task? := null
  reader/Task? := null
  try:
    link := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    client = att.Client host link
    writer = task::
      client.write-long 3 (payload 19)
      writer-ended.set true
    waiting.get
    reader = task::
      reader-started.set true
      reader-result.set (client.read 3)
    reader-started.get
    sleep --ms=1
    release.set true
    writer-ended.get
    expect-equals #[7] reader-result.get
  finally:
    if reader: reader.cancel
    if writer: writer.cancel
    if client: client.close
    host.close
    host.wait-closed
    responder.cancel

packets bytes/ByteArray [packet] -> none:
  offset := 0
  while true:
    length := min (bytes.size - offset) 18
    packet.call (prepare bytes[offset..offset + length] offset)
    offset += length
    if offset == bytes.size: return

prepare bytes/ByteArray offset/int -> ByteArray:
  result := ByteArray (5 + bytes.size)
  result[0] = 0x16
  io.LITTLE-ENDIAN.put-uint16 result 1 3
  io.LITTLE-ENDIAN.put-uint16 result 3 offset
  result.replace 5 bytes
  return result

payload length/int -> ByteArray:
  return ByteArray length: it % 251
