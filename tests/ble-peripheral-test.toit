// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.advertising-set as advertising-set
import ble.experimental.central
import ble.experimental.connection
import ble.experimental.hci
import expect show *
import monitor
import .ble-fixture as fixture

main:
  with-timeout --ms=5_000:
    expect-equals #[0xa0, 0, 0xa0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 7, 0]
        advertising-set.parameters
    expect-throw "INVALID_ARGUMENT": advertising-set.parameters --interval=31
    expect-throw "INVALID_ARGUMENT": advertising-set.data (ByteArray 32)
    bytes := #[2, 1, 6]
    encoded := advertising-set.data bytes
    expect-equals 32 encoded.size
    expect-equals #[3, 2, 1, 6] encoded[0..4]
    bytes[0] = 0
    expect-equals 2 encoded[1]
    event := fixture.connection-event.copy
    event[7] = 1
    expect-throw "HCI_UNEXPECTED_CONNECTION_ROLE": connection.decode-completion event
    expect-equals 0x234 (connection.decode-completion event --role=1).handle
    test-accept
    test-abort false
    test-abort true

reply transport/fixture.FakeTransport opcode/int parameters/ByteArray:
  expected := ByteArray (4 + parameters.size)
  expected.replace 0 #[1, opcode & 0xff, opcode >> 8, parameters.size]
  expected.replace 4 parameters
  expect-equals expected transport.sent.take
  transport.received.add #[4, 14, 4, 1, opcode & 0xff, opcode >> 8, 0]

setup transport/fixture.FakeTransport --local-random-address/ByteArray?=null:
  if local-random-address: reply transport 0x2005 local-random-address
  reply transport 0x2006 (advertising-set.parameters --own-address-type=(local-random-address ? 1 : 0))
  reply transport 0x2008 (advertising-set.data #[2, 1, 6])
  reply transport 0x2009 (advertising-set.data #[])
  reply transport 0x200a #[1]

test-accept:
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport)
  responder := task::
    2.repeat:
      setup transport
      event := fixture.connection-event.copy
      event[7] = 1
      transport.received.add event
      reply transport 0x200a #[0]
      fixture.status-reply transport #[1, 6, 4, 3, 0x34, 2, 0x13]
      transport.received.add #[4, 5, 4, 0, 0x34, 2, 0x16]
    // Reusing the owner as central restores the expected role.
    fixture.status-reply transport fixture.create-command
    transport.received.add fixture.connection-event
    fixture.status-reply transport #[1, 6, 4, 3, 0x34, 2, 0x13]
    transport.received.add #[4, 5, 4, 0, 0x34, 2, 0x16]
  try:
    2.repeat:
      link := host.accept #[2, 1, 6]
      expect link.connected
      expect-throw "HCI_CONNECTION_BUSY": host.accept #[]
      host.disconnect link
      expect-equals 0x16 link.wait-disconnected
    link := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    host.disconnect link
  finally:
    host.close
    responder.cancel

test-abort cancel/bool:
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport)
  ready := monitor.Latch
  ended := monitor.Latch
  responder := task::
    setup transport
    ready.set true
  waiter := task::
    try:
      error := catch: host.accept #[2, 1, 6] --timeout=(Duration --ms=30)
      if not cancel: expect-equals DEADLINE-EXCEEDED-ERROR error
    finally:
      critical-do --no-respect-deadline: ended.set true
  try:
    ready.get
    if cancel: waiter.cancel
    ended.get
    expect transport.closed
    expect-throw "HCI_ACCEPT_ABORTED": host.accept #[]
  finally:
    host.close
    waiter.cancel
    responder.cancel
