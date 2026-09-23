// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Data Length Extension: a controller that supports it receives the suggested
// default at initialization, and a link records the negotiated lengths.

import ble.experimental.central
import ble.experimental.connection
import ble.experimental.hci
import expect show *
import .ble-fixture as fixture

main:
  with-timeout --ms=5_000:
    supported
    unsupported
    malformed

supported:
  radio := fixture.FakeTransport
  controller := hci.Controller radio
  responder := task::
    fixture.initialize-replies radio --data-length
    fixture.status-reply radio fixture.create-command
    radio.received.add fixture.connection-event
  host/central.Central? := null
  try:
    info := hci.initialize controller
    expect-equals 0x21 info.le-features[0]
    host = central.Central controller
    link := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    expect-null link.data-length
    radio.received.add #[4, 0x3e, 11, 7, 0x34, 2, 0xfb, 0, 0x48, 8, 0x1b, 0, 0x48, 1]
    while not link.data-length: sleep --ms=1
    length := link.data-length
    expect-equals 0x234 length.handle
    expect-equals 251 length.tx-octets
    expect-equals 2120 length.tx-time
    expect-equals 27 length.rx-octets
    expect-equals 328 length.rx-time
    // A change for an unknown handle is ignored, not an error.
    radio.received.add #[4, 0x3e, 11, 7, 0x35, 2, 0xfb, 0, 0x48, 8, 0x1b, 0, 0x48, 1]
    sleep --ms=10
    expect link.connected
    expect-equals 251 link.data-length.tx-octets
  finally:
    responder.cancel
    if host: host.close
    controller.close

unsupported:
  radio := fixture.FakeTransport
  controller := hci.Controller radio
  responder := task::
    fixture.initialize-replies radio
    // No suggested-default command follows for a controller without DLE.
    fixture.status-reply radio fixture.create-command
  try:
    hci.initialize controller
    host := central.Central controller
    expect-throw DEADLINE-EXCEEDED-ERROR:
      host.connect #[1, 2, 3, 4, 5, 6] --address-type=1 --timeout=(Duration --ms=50)
  finally:
    responder.cancel
    controller.close

malformed:
  packet := #[4, 0x3e, 11, 7, 0x34, 2, 0xfb, 0, 0x48, 8, 0x1b, 0, 0x48, 1]
  expect-equals 251 (connection.decode-data-length packet).tx-octets
  expect-null (connection.decode-data-length #[4, 0x3e, 4, 4, 0, 0x34, 2])
  short := #[4, 0x3e, 10, 7, 0x34, 2, 0xfb, 0, 0x48, 8, 0x1b, 0, 0x48]
  expect-throw "HCI_MALFORMED_CONNECTION_EVENT": connection.decode-data-length short
  tiny := packet.copy
  tiny[6] = 26
  expect-throw "HCI_MALFORMED_CONNECTION_EVENT": connection.decode-data-length tiny
