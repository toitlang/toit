// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor
import ble.experimental.attribute-server as attributes
import ble.experimental.cccd-store as cccd
import ble.experimental.central
import ble.experimental.hci
import ble.experimental.security-owner
import ble.experimental.service.client as clients
import ble.experimental.signaling as signaling
import .ble-cccd-session-test as configuration
import .ble-fixture as wire
import .ble-peripheral-test as peripheral
import .ble-security-cleanup-test as security
import .ble-service-gatt-test as service

// Real service RPC and simulated HCI, with injected security evidence only.
main:
  with-timeout --ms=8_000:
    store := configuration.Store
    store.pause = true
    round store false
    expect-equals #[1, 1, 17, 0, 1, 0] store.state
    round store true
    expect-equals 1 store.saves

round store/configuration.Store restored/bool:
  provider := Provider store
  provider.install
  client := clients.Client
  client.open
  ready := monitor.Latch
  notified := monitor.Latch
  ended := monitor.Latch
  responder := task::
    try:
      radio := provider.radio
      wire.initialize-replies radio
      peripheral.setup radio
      event := wire.connection-event.copy
      event[7] = 1
      radio.received.add event
      peripheral.reply radio 0x200a #[0]
      wire.att-sent radio (signaling.parameter-request 1) --channel=5
      radio.received.add (wire.att-event #[0x13, 1, 2, 0, 0, 0] --channel=5)
      radio.received.add (wire.att-event #[0x0a, 17, 0])
      wire.att-sent radio #[0x0b, (restored ? 1 : 0), 0]
      if not restored:
        before := radio.sent-count
        radio.received.add (wire.att-event #[0x12, 17, 0, 1, 0])
        store.entered.get
        // The successful ATT response must wait for the trusted store.
        expect-equals before radio.sent-count
        store.release.set true
        wire.att-sent radio #[0x13]
      ready.set true
      wire.att-sent radio #[0x1b, 16, 0, 42]
      notified.set true
      radio.received.add #[4, 5, 4, 0, 0x34, 2, 0x13]
    finally:
      critical-do --no-respect-deadline: ended.set true
  try:
    session := client.configure
    session.add-service #[0xf0, 0xff]
    expect-equals 16 (session.add-characteristic #[0xf1, 0xff] --read --notify --value=#[42])
    session.start #[2, 1, 6]
    ready.get
    expect (session.notify 16)
    notified.get
    ended.get
    session.close
    expect-equals 1 provider.selected
    expect-equals 1 provider.owner.closes
  finally:
    store.release.set true
    client.close
    provider.uninstall
    responder.cancel

class Provider extends service.TestProvider:
  store_/cccd.Store
  owner/Owner ::= Owner
  selected/int := 0
  constructor .store_:
    super
  create-security-owner host/central.Central link/central.Link info/hci.Capabilities -> security-owner.Owner?:
    return owner
  run-security-owner owner/security-owner.Owner -> none:
  create-cccd-store host/central.Central link/central.Link database/attributes.Database owner/security-owner.Owner? -> cccd.Store?:
    expect-equals this.owner owner
    expect (owner.matches host link)
    expect-equals #[42] (database.value 16)
    selected++
    return store_

class Owner extends security.Owner:
  constructor: super false
  paired -> bool: return true
  encrypted -> bool: return true
  authenticated -> bool: return true
