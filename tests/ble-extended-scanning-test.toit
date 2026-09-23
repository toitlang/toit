// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.extended-scanning as scanning
import ble.experimental.hci
import ble.experimental.scanning show Statistics
import expect show *
import io
import monitor
import system
import .ble-advertising-parser-test as parser
import .ble-fixture as fixture

main:
  with-timeout --ms=10_000:
    test-reports
    test-mutations
    test-queue
    test-cancel
    ["callback", "deadline", "disable"].do: test-cleanup it
    radio := fixture.FakeTransport
    controller := hci.Controller radio
    try:
      info := capabilities
      info.commands[37] = 0
      expect-throw "HCI_EXTENDED_SCANNING_UNSUPPORTED": scanning.scan controller info: unreachable
      expect-throw DEADLINE-EXCEEDED-ERROR:
        with-timeout --ms=10: radio.sent.take
    finally:
      controller.close

capabilities -> hci.Capabilities:
  return hci.Capabilities #[] (ByteArray 64 --initial=0xff) #[] (ByteArray 8 --initial=0xff) #[] 27 4

record flags/int --data/ByteArray=#[2, 1, 6] -> ByteArray:
  bytes := ByteArray 24
  io.LITTLE-ENDIAN.put-uint16 bytes 0 flags
  bytes[2] = 1
  bytes.replace 3 #[1, 2, 3, 4, 5, 0x42]
  bytes[9] = 1
  bytes[11] = 0xff
  bytes[12] = 0x7f
  bytes[13] = 0xd8
  bytes[23] = data.size
  return bytes + data

event records/List -> ByteArray:
  bytes := #[0x0d, records.size]
  records.do: bytes += it
  return #[4, 0x3e, bytes.size] + bytes

test-reports:
  flags := [0x13, 0x15, 0x12, 0x10, 0x1b, 0x1a]
  retained := []
  expect (scanning.reports-do (event (flags.map: record it)):
    retained.add it)
  expect-equals [0, 1, 2, 3, 4, 4] (retained.map: it.event-type)
  system.process-stats --gc
  retained.do:
    expect-equals 1 it.address-type
    expect-equals #[1, 2, 3, 4, 5, 0x42] it.address
    expect-equals #[2, 1, 6] it.data
    expect-equals -40 it.rssi
  // Extended and fragmented data must not masquerade as complete legacy PDUs.
  expect (scanning.reports-do (event [(record 0), (record 0x20)]): unreachable)
  raw := record 0x13
  raw[13] = 0x7f
  scanning.reports-do (event [raw]): expect-equals null it.rssi
  expect (not (scanning.reports-do #[4, 5, 0]: unreachable))
  valid := event [(record 0x13), (record 0x12)]
  (valid.size - 3).repeat: | i/int |
    truncated := valid[..i + 3].copy
    truncated[2] = truncated.size - 3
    expect-throw "HCI_MALFORMED_ADVERTISING_REPORT": scanning.reports-do truncated: unreachable
  [0x30, 0x50, 0x90, 0x11].do: | bad/int |
    expect-throw "HCI_MALFORMED_ADVERTISING_REPORT":
      scanning.reports-do (event [(record 0x13), (record bad)]): unreachable
  [9, 10, 23].do: | offset/int |
    broken := record 0x13
    broken[offset] = offset == 23 ? 32 : 2
    expect-throw "HCI_MALFORMED_ADVERTISING_REPORT":
      scanning.reports-do (event [(record 0x13), broken]): unreachable
  expect-throw "HCI_MALFORMED_ADVERTISING_REPORT":
    scanning.reports-do (event []): unreachable

test-mutations:
  base := event [(record 0x13), (record 0x1b)]
  largest := event (List 10: record 0x13 --data=#[])
  random := parser.Generator
  10_000.repeat: | index/int |
    packet := (index % 2 == 0 ? base : largest).copy
    packet[random.next % packet.size] = random.next & 0xff
    if index % 3 == 0: packet = packet[..random.next % (packet.size + 1)].copy
    if packet.size >= 3: packet[2] = packet.size - 3
    delivered := 0
    failure := catch:
      scanning.reports-do packet: | report |
        delivered++
        expect-equals 6 report.address.size
        expect (report.data.size <= 31)
        expect (0 <= report.event-type <= 4)
    if failure:
      expect (failure == "HCI_MALFORMED_PACKET" or failure == "HCI_UNSUPPORTED_PACKET_TYPE" or
          failure == "HCI_MALFORMED_ADVERTISING_REPORT")
      expect-equals 0 delivered
    else:
      expect (delivered == 0 or delivered <= packet[4])

test-cancel:
  radio := fixture.FakeTransport
  controller := hci.Controller radio
  entered := monitor.Latch
  finished := monitor.Latch
  statistics := Statistics
  responder := task::
    setup radio
    radio.received.add (event [(record 0x13)])
    fixture.reply radio DISABLE #[]
    fixture.reply radio #[1, 3, 12, 0] #[]
  caller := task::
    try:
      scanning.scan controller capabilities --statistics=statistics:
        entered.set true
        (monitor.Latch).get
        true
    finally:
      critical-do: finished.set true
  try:
    entered.get
    caller.cancel
    finished.get
    expect statistics.stopped
    controller.command hci.RESET
  finally:
    caller.cancel
    controller.close
    responder.cancel

setup radio/fixture.FakeTransport:
  fixture.reply radio #[1, 1, 32, 8, 0x5f, 0x12, 0, 0, 0, 0, 0, 0] #[]
  fixture.reply radio #[1, 0x41, 32, 8, 0, 0, 1, 0, 0x10, 0, 0x10, 0] #[]
  fixture.reply radio #[1, 0x42, 32, 6, 1, 1, 0, 0, 0, 0] #[]

DISABLE ::= #[1, 0x42, 32, 6, 0, 0, 0, 0, 0, 0]

test-queue:
  radio := fixture.FakeTransport
  controller := hci.Controller radio
  statistics := Statistics
  received := []
  responder := task::
    fixture.reply radio #[1, 1, 32, 8, 0x5f, 0x12, 0, 0, 0, 0, 0, 0] #[]
    fixture.reply radio #[1, 0x41, 32, 8, 0, 0, 1, 0, 0x10, 0, 0x10, 0] #[]
    expect-equals #[1, 0x42, 32, 6, 1, 1, 0, 0, 0, 0] radio.sent.take
    // Fill the bounded report queue while enable still awaits its reply.
    5.repeat: radio.received.add (event [(record 0x13 --data=#[it])])
    radio.received.add #[4, 5, 4, 0, 1, 0, 0x13]
    radio.received.add #[4, 14, 4, 1, 0x42, 32, 0]
    fixture.reply radio DISABLE #[]
  try:
    dropped := scanning.scan controller capabilities --queue-limit=2 --statistics=statistics:
      received.add it
      system.process-stats --gc
      received.size < 2
    expect-equals 3 dropped
    expect-equals 3 statistics.dropped-events
    expect statistics.stopped
    expect-equals [#[0], #[1]] (received.map: it.data)
    expect-equals #[4, 5, 4, 0, 1, 0, 0x13] controller.receive
    reports := controller.open-reports
    controller.close-reports reports
  finally:
    controller.close
    responder.cancel

test-cleanup mode/string:
  radio := fixture.FakeTransport
  controller := hci.Controller radio
  statistics := Statistics
  responder := task::
    setup radio
    if mode != "deadline": radio.received.add (event [(record 0x13)])
    if mode == "disable":
      expect-equals DISABLE radio.sent.take
      radio.received.add #[4, 14, 4, 1, 0x42, 32, 12]
    else:
      fixture.reply radio DISABLE #[]
  try:
    error := catch:
      with-timeout --ms=100:
        scanning.scan controller capabilities --statistics=statistics:
          if mode == "callback": throw "CALLBACK_FAILED"
          false
    if mode == "callback": expect-equals "CALLBACK_FAILED" error
    else if mode == "deadline": expect-equals DEADLINE-EXCEEDED-ERROR error
    else: expect (error is hci.CommandError and error.status == 12)
    expect-equals (mode != "disable") statistics.stopped
    if mode == "disable": expect-throw "HCI_CLOSED": controller.open-reports
    else:
      reports := controller.open-reports
      controller.close-reports reports
  finally:
    controller.close
    responder.cancel
