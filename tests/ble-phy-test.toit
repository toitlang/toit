// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// LE 2M PHY: a controller that supports it gets 1M/2M defaults at
// initialization, a link owner asks for 2M after a connection it initiated
// when the peer has it too, and the link records the update.

import ble.experimental.central
import ble.experimental.connection
import ble.experimental.hci
import expect show *
import .ble-fixture as fixture

main:
  with-timeout --ms=5_000:
    supported
    peer-without-2m
    malformed

supported:
  radio := fixture.FakeTransport
  radio.auto-features = #[1, 1, 0, 0, 0, 0, 0, 0]
  controller := hci.Controller radio
  responder := task::
    fixture.initialize-replies radio --phy-2m
    fixture.status-reply radio fixture.create-command
    radio.received.add fixture.connection-event
    // The 2M request follows the feature exchange.
    fixture.status-reply radio (hci.command-packet 0x2032 #[0x34, 2, 0, 2, 2, 0, 0])
    radio.received.add #[4, 0x3e, 6, 0x0c, 0, 0x34, 2, 2, 2]
  host/central.Central? := null
  try:
    info := hci.initialize controller
    expect info.phy-2m
    host = central.Central controller --phy-2m=info.phy-2m
    link := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    while not link.phy: sleep --ms=1
    expect-equals 2 link.phy.tx
    expect-equals 2 link.phy.rx
    expect-equals 0x234 link.phy.handle
  finally:
    responder.cancel
    if host: host.close
    controller.close

peer-without-2m:
  radio := fixture.FakeTransport
  controller := hci.Controller radio
  responder := task::
    fixture.initialize-replies radio --phy-2m
    fixture.status-reply radio fixture.create-command
    radio.received.add fixture.connection-event
    // No PHY request: the next command the owner sends is the disconnect.
    fixture.status-reply radio #[1, 6, 4, 3, 0x34, 2, 0x13]
    radio.received.add #[4, 5, 4, 0, 0x34, 2, 0x16]
  try:
    info := hci.initialize controller
    host := central.Central controller --phy-2m=info.phy-2m
    link := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    expect-null link.phy
    host.disconnect link
    host.close
  finally:
    responder.cancel
    controller.close

malformed:
  expect-null (connection.decode-phy-update #[4, 0x3e, 6, 0x0c, 1, 0x34, 2, 2, 2])
  expect-throw "HCI_MALFORMED_CONNECTION_EVENT": connection.decode-phy-update #[4, 0x3e, 6, 0x0c, 0, 0x34, 2, 4, 2]
  expect-throw "HCI_MALFORMED_CONNECTION_EVENT": connection.decode-phy-update #[4, 0x3e, 5, 0x0c, 0, 0x34, 2, 2]
  expect-equals #[0x34, 2, 0, 2, 2, 0, 0] (connection.phy-2m-parameters 0x234)
