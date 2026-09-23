// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.central
import ble.experimental.connection
import ble.experimental.hci
import expect show *
import io
import monitor
import system
import .ble-fixture as fixture
import .ble-peripheral-test as peripheral

main:
  with-timeout --ms=10_000:
    routing
    transmit-disconnect
    concurrent-sends
    mixed-roles

address peer/int -> ByteArray: return #[peer, 2, 3, 4, 5, 6]

establish transport/fixture.FakeTransport peer/int handle/int:
  fixture.status-reply transport (hci.command-packet 0x200d (connection.create-parameters (address peer) --address-type=1))
  transport.received.add (connected peer handle)

connected peer/int handle/int -> ByteArray:
  event := fixture.connection-event.copy
  io.LITTLE-ENDIAN.put-uint16 event 5 handle
  event.replace 9 (address peer)
  return event

incoming transport/fixture.FakeTransport handle/int bytes/ByteArray --start/bool=false:
  packet := ByteArray (5 + bytes.size)
  packet[0] = 2
  io.LITTLE-ENDIAN.put-uint16 packet 1 (handle | (start ? 0x2000 : 0x1000))
  io.LITTLE-ENDIAN.put-uint16 packet 3 bytes.size
  packet.replace 5 bytes
  transport.received.add packet

ended transport/fixture.FakeTransport handle/int:
  event := #[4, 5, 4, 0, 0, 0, 0x13]
  io.LITTLE-ENDIAN.put-uint16 event 4 handle
  transport.received.add event

completed transport/fixture.FakeTransport handle/int:
  event := #[4, 0x13, 5, 1, 0, 0, 1, 0]
  io.LITTLE-ENDIAN.put-uint16 event 4 handle
  transport.received.add event

routing:
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport) --link-limit=2 --acl-count=2
      --early-acl-timeout=(Duration --ms=100)
  responder := task::
    establish transport 1 0x234
    fixture.status-reply transport (hci.command-packet 0x200d (connection.create-parameters (address 2) --address-type=1))
    incoming transport 0x234 #[2, 0] --start
    // Unknown B packets wait for B's completion while A continues reassembly.
    incoming transport 0x235 #[2, 0] --start
    incoming transport 0x234 #[4, 0, 0xa1, 0xa2]
    transport.received.add (connected 2 0x235)
    incoming transport 0x235 #[4, 0, 0xb1, 0xb2]
  try:
    a := host.connect (address 1) --address-type=1
    b := host.connect (address 2) --address-type=1
    expect-throw "HCI_CONNECTION_BUSY": host.connect (address 3) --address-type=1
    first := a.receive
    second := b.receive
    system.process-stats --gc
    expect-equals #[0xa1, 0xa2] first.payload
    expect-equals #[0xb1, 0xb2] second.payload
    expect-equals 1 host.early-acl-recovered
    expect (a.connected and b.connected)
    host.close
    expect-throw "HCI_CLOSED": a.receive
    expect-throw "HCI_CLOSED": b.receive
  finally:
    responder.cancel
    host.close
    host.wait-closed

transmit-disconnect:
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport) --link-limit=2 --acl-count=2 --acl-length=4
  begin := monitor.Latch
  aborted := monitor.Latch
  received := monitor.Latch
  responder := task::
    establish transport 1 0x234
    establish transport 2 0x235
    begin.get
    // A fills its quota with a partial PDU, waiting for its next credit.
    expect-equals #[2, 0x34, 2, 4, 0, 1, 0, 4, 0] transport.sent.take
    ended transport 0x234
    expect-equals "HCI_LINK_DISCONNECTED" aborted.get
    // B retains both its lifetime and access to the controller after A ends.
    expect-equals #[2, 0x35, 2, 4, 0, 1, 0, 4, 0] transport.sent.take
    completed transport 0x235
    expect-equals #[2, 0x35, 0x12, 1, 0, 0xbb] transport.sent.take
    completed transport 0x235
    received.set true
    establish transport 3 0x234
  sender/Task? := null
  try:
    a := host.connect (address 1) --address-type=1
    b := host.connect (address 2) --address-type=1
    sender = task::
      begin.set true
      error := catch: host.send a 4 #[0xaa]
      aborted.set error
    aborted.get
    expect (not transport.closed)
    expect b.connected
    host.send b 4 #[0xbb]
    received.get
    replacement := host.connect (address 3) --address-type=1
    expect (replacement != a and replacement.connected and b.connected)
    expect-throw "HCI_LINK_DISCONNECTED": host.send a 4 #[0xcc]
    expect-equals 0x13 a.wait-disconnected
  finally:
    if sender: sender.cancel
    responder.cancel
    host.close
    host.wait-closed

concurrent-sends:
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport) --link-limit=2 --acl-count=2 --acl-length=4
  ready := monitor.Latch
  peer-done := monitor.Latch
  a-done := monitor.Latch
  b-done := monitor.Latch
  responder := task::
    establish transport 1 0x234
    establish transport 2 0x235
    ready.get
    starts := []
    2.repeat:
      packet := transport.sent.take
      expect-equals #[2] packet[..1]
      handle := io.LITTLE-ENDIAN.uint16 packet 1
      expect (handle == 0x234 or handle == 0x235)
      expect (not (starts.contains handle))
      starts.add handle
      expect-equals #[4, 0, 1, 0, 4, 0] packet[3..]
    // Complete both handles in one event, after both have spent their quota.
    transport.received.add #[4, 0x13, 9, 2, 0x34, 2, 1, 0, 0x35, 2, 1, 0]
    ends := []
    2.repeat:
      packet := transport.sent.take
      handle := io.LITTLE-ENDIAN.uint16 packet 1
      expect (handle == 0x1234 or handle == 0x1235)
      expect (not (ends.contains handle))
      ends.add handle
      expect-equals #[1, 0, handle == 0x1234 ? 0xaa : 0xbb] packet[3..]
    transport.received.add #[4, 0x13, 9, 2, 0x35, 2, 1, 0, 0x34, 2, 1, 0]
    peer-done.set true
  send-a/Task? := null
  send-b/Task? := null
  try:
    a := host.connect (address 1) --address-type=1
    b := host.connect (address 2) --address-type=1
    send-a = task::
      host.send a 4 #[0xaa]
      a-done.set true
    send-b = task::
      host.send b 4 #[0xbb]
      b-done.set true
    ready.set true
    a-done.get
    b-done.get
    peer-done.get
    expect (a.connected and b.connected and not transport.closed)
  finally:
    if send-a: send-a.cancel
    if send-b: send-b.cancel
    responder.cancel
    host.close
    host.wait-closed

mixed-roles:
  transport := fixture.FakeTransport
  controller := hci.Controller transport
  expect-throw "INVALID_ARGUMENT": central.Central controller --link-limit=0
  expect-throw "INVALID_ARGUMENT": central.Central controller --link-limit=17
  expect-throw "INVALID_ARGUMENT": central.Central controller --acl-quota=0
  expect-throw "INVALID_ARGUMENT": central.Central controller --acl-quota=2
  host := central.Central controller --link-limit=2 --acl-count=2
  responder := task::
    establish transport 1 0x234
    peripheral.setup transport
    event := connected 2 0x235
    event[7] = 1
    transport.received.add event
    peripheral.reply transport 0x200a #[0]
    incoming transport 0x234 #[1, 0, 4, 0, 0xaa] --start
    incoming transport 0x235 #[1, 0, 4, 0, 0xbb] --start
  try:
    a := host.connect (address 1) --address-type=1
    b := host.accept #[2, 1, 6]
    expect-equals 0 a.info.role
    expect-equals 1 b.info.role
    expect-equals #[0xaa] a.receive.payload
    expect-equals #[0xbb] b.receive.payload
  finally:
    responder.cancel
    host.close
    host.wait-closed
