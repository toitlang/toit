// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.central
import ble.experimental.hci
import ble.experimental.security-owner
import ble.experimental.service.client as clients
import expect show *
import monitor
import .ble-bounded-accept-test as accept
import .ble-connect-isolation-test as connect
import .ble-hci-test as wire
import .ble-multilink-test as links
import .ble-security-cleanup-test as cleanup
import .ble-service-multiclient-test as packets
import .ble-service-shared-peripheral-test as fixture

main:
  with-timeout --ms=8_000: stuck-worker

stuck-worker:
  provider := Provider
  provider.install
  client := clients.Client
  client.open
  pool := provider.reserve-shared-host
  disconnected := monitor.Latch
  responder := task::
    wire.initialize-replies provider.radio
    owner/central.Central := provider.ready.get
    connect.establish provider.radio owner 1 0x234 --extended-mode
    accept.setup provider.radio
    accept.enabled provider.radio
    accept.connected provider.radio
    accept.terminal provider.radio --won
    accept.remove provider.radio
    packet := provider.radio.sent.take
    expect-equals #[2, 0x35, 2] packet[..3]
    expect-equals #[5, 0] packet[7..9]
    links.completed provider.radio 0x235
    packets.disconnect provider.radio 0x235
    disconnected.set true
  survivor/central.Link? := null
  try:
    pool.setup: | owner/central.Central info/hci.Capabilities |
      survivor = owner.connect (links.address 1) --address-type=1
    session := client.session
    session.peer
    provider.started.get
    session.close
    disconnected.get
    // The serving worker's security join has a three-second deadline. Keep
    // the security task deliberately unresponsive beyond that boundary.
    sleep --ms=3_200
    expect (not provider.ended.has-value)
    expect provider.radio.closed
    expect (not survivor.connected)
    expect (not provider.last.is-released)
    expect-throw "GATT_SERVICE_BUSY": pool.retain
    provider.release.set true
    provider.ended.get
    yield
    expect (not provider.last.is-released)
    expect-throw "GATT_SERVICE_BUSY": client.configure
    expect-equals 1 provider.hook.closes
  finally:
    provider.release.set true
    if provider.started.has-value: provider.ended.get
    client.close
    pool.fail
    pool.release
    provider.uninstall
    responder.cancel

class Provider extends fixture.Provider:
  started/monitor.Latch ::= monitor.Latch
  release/monitor.Latch ::= monitor.Latch
  ended/monitor.Latch ::= monitor.Latch

  constructor:
    super "normal"
    hook = cleanup.Owner false

  run-security-owner owner/security-owner.Owner -> none:
    try:
      critical-do --no-respect-deadline:
        started.set true
        release.get
    finally:
      critical-do --no-respect-deadline: ended.set true
