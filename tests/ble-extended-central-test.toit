// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.att
import ble.experimental.extended-central as extended
import ble.experimental.hci
import expect show *
import io
import .ble-connect-isolation-test as isolation
import .ble-fixture as fixture
import .ble-multilink-test as links

main:
  with-timeout --ms=25_000:
    encoding
    decoding
    configured-traffic
    [false, true].do: | configuring/bool |
      ["cancel", "deadline", "rejected", "missing"].do:
        isolation.interrupted configuring it --extended-mode
    ["won", "missing-completion", "failed-cancel"].do:
      isolation.interrupted false it --extended-mode

encoding:
  address := #[1, 2, 3, 4, 5, 6]
  expected := #[0, 0, 1, 1, 2, 3, 4, 5, 6, 1, 16, 0, 16, 0, 24, 0, 40, 0, 0, 0, 144, 1, 0, 0, 0, 0]
  parameters := extended.create-parameters address --address-type=1
  expect-equals expected parameters
  address.fill 0
  expect-equals expected parameters
  expected[1] = 1
  expected[2] = 0
  expect-equals expected (extended.create-parameters #[1, 2, 3, 4, 5, 6] --address-type=0 --own-address-type=1)
  expect-throw "INVALID_ARGUMENT": extended.create-parameters #[] --address-type=0
  expect-throw "INVALID_ARGUMENT": extended.create-parameters address --address-type=2
  expect-throw "INVALID_ARGUMENT": extended.create-parameters address --address-type=0 --own-address-type=2

decoding:
  packet := isolation.completed-connection 1 0x234
  result := extended.decode-completion packet
  expect-equals 0x234 result.handle
  expect-equals (links.address 1) result.address
  expect-equals 1 result.address-type
  expect-equals 0 result.role
  expect-equals 24 result.interval
  expect-equals 0 result.latency
  expect-equals 400 result.supervision-timeout
  packet[9] = 99
  expect-equals (links.address 1) result.address
  packet[7] = 1
  expect-equals 1 (extended.decode-completion packet --role=1).role
  expect-throw "HCI_UNEXPECTED_CONNECTION_ROLE": extended.decode-completion packet
  expect-equals null (extended.decode-completion fixture.connection-event)
  expect-equals null (extended.decode-completion #[4, 5, 0])
  expect-throw "INVALID_ARGUMENT": extended.decode-completion packet --role=2
  [5, 8, 15, 26, 27, 29, 31].do: | offset/int |
    malformed := isolation.completed-connection 1 0x234
    expected := "HCI_MALFORMED_CONNECTION_EVENT"
    if offset == 5: io.LITTLE-ENDIAN.put-uint16 malformed offset 0x0f00
    if offset == 8: malformed[offset] = 2
    if offset == 15 or offset == 26:
      malformed[offset] = 1
      expected = "HCI_UNEXPECTED_CONTROLLER_PRIVACY"
    if offset == 27: io.LITTLE-ENDIAN.put-uint16 malformed offset 5
    if offset == 29: io.LITTLE-ENDIAN.put-uint16 malformed offset 500
    if offset == 31: io.LITTLE-ENDIAN.put-uint16 malformed offset 9
    expect-throw expected: extended.decode-completion malformed
    // Failed completions have no meaningful handle, role, timing or addresses.
    malformed[4] = 2
    failed := extended.decode-completion malformed
    expect-equals 2 failed.status
    expect-equals 0 failed.handle
    expect-equals #[] failed.address
  short := packet[..33].copy
  short[2] = 30
  expect-throw "HCI_MALFORMED_CONNECTION_EVENT": extended.decode-completion short

configured-traffic:
  radio := fixture.FakeTransport
  controller := hci.Controller radio
  host/extended.Central? := null
  client/att.Client? := null
  responder := task::
    fixture.initialize-replies radio
    fixture.reply radio #[1, 1, 0x20, 8, 0x5f, 2, 0, 0, 0, 0, 0, 0] #[]
    fixture.status-reply radio #[1, 0x43, 0x20, 26, 0, 0, 1, 1, 2, 3, 4, 5, 6, 1, 16, 0, 16, 0, 24, 0, 40, 0, 0, 0, 144, 1, 0, 0, 0, 0]
    radio.received.add (isolation.completed-connection 1 0x234)
    fixture.gatt-reply radio #[0x0a, 3, 0] #[0x0b, 42]
  try:
    info := hci.initialize controller
    info.le-features[1] = 0
    expect-throw "HCI_EXTENDED_ADVERTISING_UNSUPPORTED": extended.configure controller info
    info.le-features[1] = 0x10
    info.commands[37] = 0
    expect-throw "HCI_EXTENDED_INITIATING_UNSUPPORTED": extended.configure controller info
    info.commands[37] = 0x80
    extended.configure controller info
    host = extended.Central controller
    // The legacy accept path must never send commands in this lifetime.
    expect-throw "HCI_EXTENDED_ADVERTISING_REQUIRED": host.accept #[]
    client = att.Client host (host.connect (links.address 1) --address-type=1)
    expect-equals #[42] (client.read 3)
    expect (not radio.closed)
  finally:
    responder.cancel
    if client: client.close
    if host:
      host.close
      host.wait-closed
    else:
      controller.close
      controller.wait-closed
