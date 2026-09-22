// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.service.client as clients
import expect show *
import monitor
import .ble-hci-test as fixture
import .ble-service-central-test as plain
import .ble-service-central-security-test as secure
import .ble-service-multiclient-test as shared
import .ble-multilink-test as links

main:
  with-timeout --ms=15_000:
    shared-rejection false
    shared-rejection true
    ["plain", "ready", "authenticated"].do: | mode/string |
      [false, true].do: | encryption/bool |
        [false, true].do: | authentication/bool |
          [false, true].do: | scoped/bool |
            run mode encryption authentication scoped

shared-rejection authentication/bool:
  provider := shared.Provider
  provider.install
  first := clients.Client
  second := clients.Client
  first.open
  second.open
  ended := monitor.Latch
  responder := task::
    radio := provider.radio
    fixture.initialize-replies radio
    links.establish radio 1 0x234
    links.establish radio 2 0x235
    // The rejected link is disconnected before any ATT access on it.
    shared.disconnect radio 0x235
    shared.sent radio 0x234 #[0x0a, 3, 0]
    shared.incoming radio 0x234 #[0x0b, 11]
    links.establish radio 3 0x235
    shared.sent radio 0x235 #[0x0a, 3, 0]
    shared.incoming radio 0x235 #[0x0b, 33]
    shared.disconnect radio 0x235
    shared.sent radio 0x234 #[0x0a, 3, 0]
    shared.incoming radio 0x234 #[0x0b, 12]
    shared.disconnect radio 0x234
    ended.set true
  try:
    survivor := first.connect (links.address 1) --address-type=1
    expect-throw "GATT_CENTRAL_SECURITY_REQUIRED":
      second.with-connection (links.address 2) --address-type=1
          --require-encryption=(not authentication)
          --require-authentication=authentication: | connection/clients.Connection |
        unreachable
    expect (not provider.radio.closed)
    expect-equals #[11] (survivor.read 3)
    // The same client can immediately reuse its released slot, including the
    // controller handle, while the first client's original link stays live.
    second.with-connection (links.address 3) --address-type=1: | replacement/clients.Connection |
      expect-equals #[33] (replacement.read 3)
    expect-equals #[12] (survivor.read 3)
    survivor.disconnect
    ended.get
    expect provider.radio.closed
    expect-equals 1 provider.opens
  finally:
    responder.cancel
    first.close
    second.close
    provider.uninstall

run mode/string encryption/bool authentication/bool scoped/bool:
  provider := mode == "plain" ? (plain.Provider) : (secure.Provider mode)
  radio := mode == "plain"
      ? (provider as plain.Provider).radio
      : (provider as secure.Provider).radio
  allowed := (not encryption or mode != "plain") and
      (not authentication or mode == "authenticated")
  provider.install
  client := clients.Client
  client.open
  ended := monitor.Latch
  setup-sends := 0
  responder := task::
    fixture.initialize-replies radio
    fixture.status-reply radio fixture.create-command
    radio.received.add fixture.connection-event
    setup-sends = radio.sent-count
    if mode != "plain":
      selected := provider as secure.Provider
      selected.entered.get
      radio.received.add #[4, 8, 4, 0, 0x34, 2, 1]
      selected.release.set true
    if allowed:
      fixture.gatt-reply radio #[0x0a, 3, 0] #[0x0b, 42]
    fixture.status-reply radio #[1, 6, 4, 3, 0x34, 2, 0x13]
    radio.received.add #[4, 5, 4, 0, 0x34, 2, 0x16]
    ended.set true
  entered := false
  try:
    error := catch:
      if scoped:
        client.with-connection #[1, 2, 3, 4, 5, 6] --address-type=1
            --require-encryption=encryption
            --require-authentication=authentication: | connection/clients.Connection |
          entered = true
          expect-equals #[42] (connection.read 3)
      else:
        connection := client.connect #[1, 2, 3, 4, 5, 6] --address-type=1
            --require-encryption=encryption
            --require-authentication=authentication
        entered = true
        try:
          expect-equals #[42] (connection.read 3)
        finally:
          connection.disconnect
    expect-equals allowed entered
    expect-equals (allowed ? null : "GATT_CENTRAL_SECURITY_REQUIRED") error
    ended.get
    while not radio.closed: sleep --ms=1
    // Rejection sends only Disconnect after setup, never an attribute request.
    if not allowed: expect-equals (setup-sends + 1) radio.sent-count
    if mode != "plain": expect (provider as secure.Provider).owner.closed
    replacement := client.configure
    replacement.close
  finally:
    responder.cancel
    client.close
    provider.uninstall
