// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor
import system
import ble.experimental.attribute-server as attributes
import ble.experimental.central
import ble.experimental.gatt-server
import ble.experimental.hci
import ble.experimental.security-owner
import ble.experimental.service.client as clients
import ble.experimental.signaling
import .ble-cccd-session-test as configuration
import .ble-service-cccd-test as service
import .ble-hci-test as wire
import .ble-peripheral-test as peripheral
import .ble-mtu-server-test as packets

STATE ::= #[0x81, 2, 9, 0, 2, 0, 13, 0, 1, 0]

main:
  with-timeout --ms=12_000:
    store := configuration.Store
    store.state = STATE.copy
    service-round store --pending --no-confirm --late-security
    expect-equals STATE store.state
    expect-equals 0 store.saves
    service-round store --pending --confirm
    expect-equals #[1, 2, 9, 0, 2, 0, 13, 0, 1, 0] store.state
    expect-equals 1 store.saves
    service-round store --no-pending --confirm
    expect-equals 1 store.saves
    receipt-clear false
    receipt-clear true

class Provider extends service.Provider:
  ready/monitor.Latch ::= monitor.Latch
  constructor store/configuration.Store: super store
  run-security-owner owner/security-owner.Owner -> none: ready.get

service-round store/configuration.Store --pending/bool --confirm/bool --late-security/bool=false:
  provider := Provider store
  if not late-security: provider.ready.set true
  provider.install
  client := clients.Client
  client.open
  observed := monitor.Latch
  proceed := monitor.Latch
  cleared := monitor.Latch
  ended := monitor.Latch
  radio := provider.radio
  responder := task::
    try:
      wire.initialize-replies radio
      peripheral.setup radio
      event := wire.connection-event.copy
      event[7] = 1
      radio.received.add event
      peripheral.reply radio 0x200a #[0]
      wire.att-sent radio (signaling.parameter-request 1) --channel=5
      radio.received.add (wire.att-event #[0x13, 1, 2, 0, 0, 0] --channel=5)
      if late-security:
        // Serving begins while the trusted owner's setup is still pending.
        radio.received.add (wire.att-event #[0x0a, 13, 0])
        wire.att-sent radio #[0x0b, 1, 0]
        provider.ready.set true
      if pending:
        wire.att-sent radio #[0x1d, 8, 0, 1, 0, 0xff, 0xff]
      observed.set true
      proceed.get
      if pending and confirm:
        store.pause = true
        radio.received.add (wire.att-event #[0x1e])
        store.entered.get
        expect-equals 0x81 store.state[0]
        system.process-stats --gc
        store.release.set true
      if confirm:
        // This response is ordered after durable confirmation processing.
        radio.received.add (wire.att-event #[0x0a, 13, 0])
        wire.att-sent radio #[0x0b, 1, 0]
        cleared.set true
        wire.att-sent radio #[0x1b, 12, 0, 42]
      radio.received.add #[4, 5, 4, 0, 0x34, 2, 0x13]
    finally:
      critical-do --no-respect-deadline: ended.set true
  try:
    session := client.configure
    session.add-service #[0xf0, 0xff]
    session.add-characteristic #[0xf1, 0xff] --read --notify --value=#[42]
    session.start #[2, 1, 6]
    observed.get
    if pending: expect (not (session.notify 12))
    proceed.set true
    if confirm:
      cleared.get
      expect (session.notify 12)
    ended.get
    session.close
    expect-equals 1 provider.selected
    expect-equals 1 provider.owner.closes
  finally:
    store.pause = false
    store.release.set true
    provider.ready.set true
    client.close
    provider.uninstall --wait
    responder.cancel

receipt-clear fail/bool:
  database := attributes.Database.with-defaults
  database.add-service #[0xf0, 0xff]
  database.add-characteristic #[0xf1, 0xff] --read --notify --value=#[42]
  store := configuration.Store
  store.state = STATE.copy
  radio := wire.FakeTransport
  host := central.Central (hci.Controller radio)
  server/gatt-server.Server? := null
  submitted := monitor.Latch
  waiter-ended := monitor.Latch
  waiter := task::
    receipt/gatt-server.Indication := submitted.get
    waiter-ended.set ((catch: receipt.wait) or true)
  responder := task::
    wire.status-reply radio wire.create-command
    radio.received.add wire.connection-event
    // An unsolicited confirmation cannot clear stored pending information.
    packets.incoming radio #[0x1e]
    packets.incoming radio #[0x12, 13, 0, 1, 0]
    packets.outgoing radio #[0x13]
    packets.outgoing radio #[0x1d, 8, 0, 1, 0, 0xff, 0xff]
    packets.incoming radio #[0x1e]
    store.entered.get
    expect (not waiter-ended.has-value)
    expect-equals 0x81 store.state[0]
    // The wire confirmation already arrived: its 50 ms timer must not expire
    // while the separate durable-store operation remains within its deadline.
    sleep --ms=100
    expect (not waiter-ended.has-value)
    store.release.set true
    expect-equals (fail ? "GATT_SERVER_CLOSED" : true) waiter-ended.get
    if not fail: radio.received.add #[4, 5, 4, 0, 0x34, 2, 0x13]
  try:
    link := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    server = gatt-server.Server host link database --pairing=service.Owner --cccd-store=store
    error := catch:
      server.serve: | handle/int _ |
        expect-equals 13 handle
        expect-equals 0x81 store.state[0]
        store.pause = true
        store.fail = fail
        submitted.set (server.indicate 8 --timeout=(Duration --ms=50))
    expect-equals (fail ? "STORE_FAILED" : null) error
    expect-equals 1 store.state[0]
    expect-equals 2 store.saves
  finally:
    store.release.set true
    waiter.cancel
    responder.cancel
    if server: server.close
    host.close
    host.wait-closed
