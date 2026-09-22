// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.att
import ble.experimental.attribute-server as attributes
import ble.experimental.central
import ble.experimental.gatt-server
import ble.experimental.hci
import ble.experimental.signaling
import expect show *
import monitor
import .ble-hci-test as fixture
import .ble-peripheral-test as peripheral

main:
  // Core 6.3 Vol 3 Part H 3.3, Table 3.3: 0 and 15..255 are RFU.
  256.repeat: | code/int |
    if code != 0 and code <= 0x0e: continue.repeat
    [1, 2, 23, 65].do: | size/int |
      bytes := ByteArray size --initial=0xa5
      bytes[0] = code
      original := bytes.copy
      expect-null (signaling.security-response bytes)
      expect-equals original bytes
  expect-equals #[5, 5] (signaling.security-response #[0x0b, 1])
  expect-equals #[5, 5] (signaling.security-response #[1, 3, 0, 8, 16, 0, 0])
  expect-null (signaling.security-response #[5, 5])
  expect-throw "SMP_INVALID_PDU": signaling.security-response #[]
  with-timeout --ms=10_000:
    routed
    routed --peripheral-role

routed --peripheral-role/bool=false:
  radio := fixture.FakeTransport
  host := central.Central (hci.Controller radio)
  client/att.Client? := null
  finished := monitor.Latch
  responder := task::
    if peripheral-role:
      peripheral.setup radio
      event := fixture.connection-event.copy
      event[7] = 1
      radio.received.add event
      peripheral.reply radio 0x200a #[0]
    else:
      fixture.status-reply radio fixture.create-command
      radio.received.add fixture.connection-event
    256.repeat: | code/int |
      if code != 0 and code <= 0x0e: continue.repeat
      radio.received.add (fixture.att-event #[code, 0xa5] --channel=6)
      // A known request follows each RFU packet in the same ordered ACL
      // stream. Its exact reply proves the ignored packet sent no reply,
      // without timing-based silence checks or flooding the receive queue.
      request := peripheral-role ? #[1, 3, 0, 8, 16, 0, 0] : #[0x0b, 1]
      radio.received.add (fixture.att-event request --channel=6)
      fixture.att-sent radio #[5, 5] --channel=6
    radio.received.add (fixture.att-event #[5, 5] --channel=6)
    if peripheral-role:
      radio.received.add (fixture.att-event #[0x0a, 3, 0])
      fixture.att-sent radio #[0x0b, 42]
      radio.received.add #[4, 5, 4, 0, 0x34, 2, 0x13]
      finished.set true
    else:
      finished.set true
      fixture.att-sent radio #[0x0a, 3, 0]
      radio.received.add (fixture.att-event #[0x0b, 42])
  try:
    if peripheral-role:
      database := attributes.Database
      database.add-service #[0xf0, 0xff]
      database.add-characteristic #[0xf1, 0xff] --read --value=#[42]
      link := host.accept #[2, 1, 6]
      server := gatt-server.Server host link database
      server.serve: | handle/int value/ByteArray | throw "UNEXPECTED_WRITE"
      finished.get
    else:
      link := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
      client = att.Client host link
      finished.get
      expect-equals #[42] (client.read 3)
      expect link.connected
  finally:
    responder.cancel
    if client: client.close
    host.close
    host.wait-closed
