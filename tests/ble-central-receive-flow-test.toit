// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.central
import ble.experimental.hci
import expect show *
import io
import monitor
import system
import .ble-fixture as fixture
import .ble-hci-receive-flow-test as flow
import .ble-multilink-test as links

main:
  with-timeout --ms=5_000: exercise

exercise:
  radio := DeferredRadio
  controller := hci.Controller radio
  host/central.Central? := null
  ready := monitor.Latch
  done := monitor.Latch
  responder := task::
    flow.initialize-radio radio --count=2
    links.establish radio 1 0x234
    links.establish radio 2 0x235
    // Both links need another fragment after exhausting the shared window.
    links.incoming radio 0x234 #[2, 0] --start
    links.incoming radio 0x235 #[2, 0] --start
    expect-credit radio 0x234
    expect-credit radio 0x235
    links.incoming radio 0x234 #[4, 0, 0xa1, 0xa2]
    links.incoming radio 0x235 #[4, 0, 0xb1, 0xb2]
    expect-credit radio 0x234
    expect-credit radio 0x235
    ready.get
    links.incoming radio 0x234 #[1, 0, 4, 0, 0xee] --start
    radio.entered.get
    links.ended radio 0x234
    links.incoming radio 0x235 #[1, 0, 4, 0, 0xb3] --start
    radio.received.add #[4, 0xff, 0]
    // The blocked old credit must be suppressed. Only B's credit is submitted.
    expect-credit radio 0x235
    links.establish radio 3 0x234
    links.incoming radio 0x234 #[1, 0, 4, 0, 0xc1] --start
    links.incoming radio 0x235 #[1, 0, 4, 0, 0xb4] --start
    expect-credit radio 0x234
    expect-credit radio 0x235
    done.set true
  try:
    hci.initialize controller --receive-acl-packets=2
    host = central.Central controller --link-limit=2 --acl-count=8
    a := host.connect (links.address 1) --address-type=1
    b := host.connect (links.address 2) --address-type=1
    first := a.receive
    second := b.receive
    system.process-stats --gc
    expect-equals #[0xa1, 0xa2] first.payload
    expect-equals #[0xb1, 0xb2] second.payload
    ready.set true
    expect-equals #[0xee] a.receive.payload
    radio.marker.get
    // Reading the marker requires the raw reader to have retired A already.
    radio.resume.set true
    expect-equals 0x13 a.wait-disconnected
    expect-equals #[0xb3] b.receive.payload
    expect b.connected
    replacement := host.connect (links.address 3) --address-type=1
    expect-equals #[0xc1] replacement.receive.payload
    expect-equals #[0xb4] b.receive.payload
    done.get
    expect-equals 8 radio.attempts
    expect-throw "HCI_LINK_DISCONNECTED": host.send a 4 #[0]
    expect (b.connected and replacement.connected)
  finally:
    responder.cancel
    if host:
      host.close
      host.wait-closed
    else:
      controller.close
      controller.wait-closed

expect-credit radio/fixture.FakeTransport handle/int:
  command := #[1, 0x35, 0x0c, 5, 1, 0, 0, 1, 0]
  io.LITTLE-ENDIAN.put-uint16 command 5 handle
  expect-equals command radio.sent.take

class DeferredRadio extends fixture.FakeTransport:
  entered/monitor.Latch ::= monitor.Latch
  resume/monitor.Latch ::= monitor.Latch
  marker/monitor.Latch ::= monitor.Latch
  attempts/int := 0

  receive -> ByteArray:
    packet := super
    if packet == #[4, 0xff, 0]: marker.set true
    return packet

  send-if packet/ByteArray [allowed] -> bool:
    attempts++
    if attempts == 5:
      entered.set true
      resume.get
    return super packet allowed
