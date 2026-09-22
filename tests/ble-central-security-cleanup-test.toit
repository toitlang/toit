// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.central
import ble.experimental.hci
import ble.experimental.security-owner
import ble.experimental.service.central-provider as providers
import ble.experimental.service.client as clients
import ble.experimental.service.provider as rpc
import expect show *
import .ble-hci-test as fixture
import .ble-multilink-test as links
import .ble-security-cleanup-test as cleanup
import .ble-service-multiclient-test as connections

main:
  [1, 2].do: | limit/int |
    with-timeout --ms=5_000:
      provider := Provider limit
      provider.install
      client := clients.Client
      client.open
      responder := task::
        fixture.initialize-replies provider.radio
        links.establish provider.radio 1 0x234
        if limit == 2: connections.disconnect provider.radio 0x234
        fixture.initialize-replies provider.recovery
        links.establish provider.recovery 1 0x234
        fixture.gatt-reply provider.recovery #[0x0a, 3, 0] #[0x0b, 42]
        connections.disconnect provider.recovery 0x234
      try:
        expect-throw "CENTRAL_SECURITY_RUN_FAILED":
          client.connect (links.address 1) --address-type=1
        while not provider.last.is-released: sleep --ms=1
        expect provider.radio.closed
        expect-equals 1 provider.owner.closes
        next := client.connect (links.address 1) --address-type=1
        expect-equals #[42] (next.read 3)
        next.disconnect
        while not provider.last.is-released: sleep --ms=1
        expect provider.recovery.closed
        expect-equals 2 provider.opens
      finally:
        client.close
        provider.uninstall
        responder.cancel
  shared-survivor

shared-survivor:
  with-timeout --ms=5_000:
    provider := SharedProvider
    provider.install
    client := clients.Client
    other := clients.Client
    client.open
    other.open
    responder := task::
      fixture.initialize-replies provider.radio
      links.establish provider.radio 1 0x234
      links.establish provider.radio 2 0x235
      connections.disconnect provider.radio 0x235
      connections.sent provider.radio 0x234 #[0x0a, 3, 0]
      connections.incoming provider.radio 0x234 #[0x0b, 42]
      links.establish provider.radio 3 0x235
      connections.sent provider.radio 0x235 #[0x0a, 3, 0]
      connections.incoming provider.radio 0x235 #[0x0b, 43]
      connections.disconnect provider.radio 0x235
      connections.disconnect provider.radio 0x234
    try:
      survivor := client.connect (links.address 1) --address-type=1
      expect-throw "CENTRAL_SECURITY_RUN_FAILED":
        other.connect (links.address 2) --address-type=1
      while not provider.last.is-released: sleep --ms=1
      expect (not provider.radio.closed)
      expect-equals 1 provider.owner.closes
      expect-equals #[42] (survivor.read 3)
      replacement := other.connect (links.address 3) --address-type=1
      expect-equals #[43] (replacement.read 3)
      replacement.disconnect
      survivor.disconnect
      expect provider.radio.closed
      expect-equals 1 provider.opens
    finally:
      other.close
      client.close
      provider.uninstall
      responder.cancel

class SharedProvider extends Provider:
  constructor: super 2
  create-central-security-owner host/central.Central link/central.Link info/hci.Capabilities -> security-owner.Owner?:
    return link.info.address[0] == 2 ? owner : null

class Provider extends providers.Provider:
  limit_/int
  radio/fixture.FakeTransport ::= fixture.FakeTransport
  recovery/fixture.FakeTransport ::= fixture.FakeTransport
  owner/cleanup.Owner ::= cleanup.Owner true
  last/rpc.Session? := null
  opens/int := 0
  constructor .limit_: super
  central-session-limit -> int: return limit_
  open-transport -> fixture.FakeTransport:
    opens++
    return opens == 1 ? radio : recovery
  create-central-security-owner host/central.Central link/central.Link info/hci.Capabilities -> security-owner.Owner?:
    return opens == 1 ? owner : null
  run-central-security-owner selected/security-owner.Owner -> none:
    throw "CENTRAL_SECURITY_RUN_FAILED"
  create-connection client/int arguments/List -> rpc.Session:
    last = super client arguments
    return last
