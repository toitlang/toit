// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Link operations through the service (PHY, RSSI, transmit power, parameters,
// disconnect reason) and the provider-wide adapter description.

import expect show *
import monitor
import ble.experimental.transport
import ble.experimental.service.client as clients
import ble.experimental.service.gatt-provider as providers
import .ble-fixture as fixture

main:
  with-timeout --ms=10_000:
    link-operations
    probe

link-operations:
  provider := Provider
  provider.install
  client := clients.Client
  client.open
  disconnect := monitor.Latch
  ended := monitor.Latch
  responder := task::
    try:
      radio := provider.radio
      fixture.initialize-replies radio
      fixture.status-reply radio fixture.create-command
      radio.received.add fixture.connection-event
      // LE Set PHY, then the PHY Update Complete it causes.
      fixture.status-reply radio #[1, 0x32, 0x20, 7, 0x34, 2, 0, 2, 2, 0, 0]
      radio.received.add #[4, 0x3e, 6, 0x0c, 0, 0x34, 2, 2, 2]
      // A rejected PHY update reports the controller's status.
      fixture.status-reply radio #[1, 0x32, 0x20, 7, 0x34, 2, 0, 4, 4, 0, 0]
      radio.received.add #[4, 0x3e, 6, 0x0c, 0x11, 0x34, 2, 0, 0]
      fixture.reply radio #[1, 0x05, 0x14, 2, 0x34, 2] #[0x34, 2, 0xc4]
      fixture.reply radio #[1, 0x2d, 0x0c, 3, 0x34, 2, 0] #[0x34, 2, 9]
      fixture.reply radio #[1, 0x2d, 0x0c, 3, 0x34, 2, 1] #[0x34, 2, 12]
      fixture.status-reply radio #[1, 0x13, 0x20, 14, 0x34, 2, 40, 0, 56, 0, 0, 0, 0x90, 1, 0, 0, 0, 0]
      radio.received.add #[4, 0x3e, 10, 3, 0, 0x34, 2, 48, 0, 0, 0, 0x90, 1]
      disconnect.get
      radio.received.add #[4, 5, 4, 0, 0x34, 2, 0x13]
    finally:
      critical-do --no-respect-deadline: ended.set true
  try:
    connection := client.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    expect-equals [0, 1, 1, 27, 27, 24, 0, 400, #[1, 2, 3, 4, 5, 6], 1, null, null] connection.link-info
    expect-equals [2, 2] (connection.set-phy --tx=2 --rx=2)
    expect-equals 2 connection.link-info[1]
    expect-equals "HCI_COMMAND_FAILED opcode=8242 status=17" (catch: connection.set-phy --tx=4 --rx=4)
    expect-equals -60 connection.rssi
    expect-equals 9 connection.tx-power
    expect-equals 12 (connection.tx-power --maximum)
    expect-equals [48, 0, 400]
        connection.update-parameters --interval-min=40 --interval-max=56 --latency=0 --supervision-timeout=400
    expect-equals 48 connection.link-info[5]
    info := client.adapter-info
    expect-equals 6 info[0].size
    expect-equals [false, null, false] info[1..]
    expect-throw "BLE_UNSUPPORTED": client.set-tx-power 3
    reason := monitor.Latch
    waiter := task:: reason.set connection.wait-disconnected
    disconnect.set true
    expect-equals 0x13 reason.get
    expect-throw "HCI_LINK_DISCONNECTED": connection.rssi
    expect-equals 0 connection.link-info[0]
    connection.disconnect
    ended.get
  finally:
    client.close
    responder.cancel
    provider.uninstall

/** The provider opens an idle controller once to describe it. */
probe:
  provider := Provider
  provider.install
  client := clients.Client
  client.open
  responder := task:: fixture.initialize-replies provider.radio
  try:
    info := client.adapter-info
    expect-equals 6 info[0].size
    expect provider.radio.closed
    // The description is remembered; no second probe.
    expect-equals info client.adapter-info
  finally:
    client.close
    responder.cancel
    provider.uninstall

class Provider extends providers.Provider:
  radio/fixture.FakeTransport := fixture.FakeTransport
  constructor: super
  open-transport -> transport.Transport: return radio
