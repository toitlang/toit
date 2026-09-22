// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.central
import ble.experimental.hci
import ble.experimental.service.client as clients
import ble.experimental.service.gatt-provider as providers
import ble.experimental.service.provider as rpc
import ble.experimental.security-owner
import ble.experimental.signaling
import expect show *
import monitor
import .ble-fixture as fixture
import .ble-peripheral-test as peripheral
import .ble-security-cleanup-test as cleanup

main:
  run false
  run true
  transport-close-failure

transport-close-failure:
  with-timeout --ms=5_000:
    provider := CloseFailureProvider
    provider.install
    client := clients.Client
    client.open
    responder := task::
      fixture.initialize-replies provider.radio
      peripheral.setup provider.radio
      event := fixture.connection-event.copy
      event[7] = 1
      provider.radio.received.add event
      peripheral.reply provider.radio 0x200a #[0]
      fixture.att-sent provider.radio (signaling.parameter-request 1) --channel=5
    try:
      session := client.session
      session.peer
      catch: session.close
      provider.joined.get
      expect (not provider.last.is-released)
      expect-throw "GATT_SERVICE_BUSY": client.configure
      expect client.capabilities.gatt-peripheral
      expect-equals 1 provider.radio.closes
    finally:
      catch: client.close
      provider.uninstall
      responder.cancel

class JoinedHost extends central.Central:
  joined_/monitor.Latch
  constructor controller/hci.Controller info/hci.Capabilities .joined_:
    super controller --acl-length=info.acl-length --acl-count=info.acl-count
  wait-closed -> none:
    super
    if not joined_.has-value: joined_.set true

class CloseTransport extends fixture.FakeTransport:
  closes/int := 0
  close -> none:
    closes++
    // Leave receive blocked; controller cancellation must still join it.
    throw "TRANSPORT_CLOSE_FAILED"

class CloseFailureProvider extends providers.Provider:
  radio/CloseTransport ::= CloseTransport
  joined/monitor.Latch ::= monitor.Latch
  last/rpc.Session? := null
  open-transport -> fixture.FakeTransport: return radio
  create-host controller/hci.Controller info/hci.Capabilities receive-limit/int -> central.Central:
    return JoinedHost controller info joined
  create-session client/int -> rpc.Session:
    last = super client
    return last

run run-failure/bool:
  with-timeout --ms=5_000:
    provider := Provider run-failure
    provider.install
    client := clients.Client
    client.open
    responder := task::
      fixture.initialize-replies provider.radio
      peripheral.setup provider.radio
      event := fixture.connection-event.copy
      event[7] = 1
      provider.radio.received.add event
      peripheral.reply provider.radio 0x200a #[0]
      if run-failure:
        fixture.att-sent provider.radio (signaling.parameter-request 1) --channel=5
      fixture.initialize-replies provider.recovery
      peripheral.setup provider.recovery
      provider.recovery.received.add event.copy
      peripheral.reply provider.recovery 0x200a #[0]
      fixture.att-sent provider.recovery (signaling.parameter-request 1) --channel=5
      provider.recovery.received.add #[4, 5, 4, 0, 0x34, 2, 0x13]
    try:
      session := client.session
      if run-failure:
        session.peer
        expect-throw "SECURITY_RUN_FAILED": session.next
      else:
        // Server construction fails after the provider installed its owner.
        expect-throw "SECURITY_MATCH_FAILED": session.peer
      session.close
      while not provider.last.is-released: sleep --ms=1
      expect provider.radio.closed
      expect-equals 1 provider.owner.closes
      // A failed cleanup hook must not strand the provider's admission slot.
      next := client.configure
      next.close
      recovered := client.session
      expect-equals 6 recovered.peer[0].size
      recovered.close
      while not provider.last.is-released: sleep --ms=1
      expect provider.recovery.closed
      expect-equals 2 provider.opens
      expect client.capabilities.gatt-peripheral
    finally:
      client.close
      provider.uninstall
      responder.cancel

class Owner extends cleanup.Owner:
  run-failure_/bool
  constructor .run-failure_: super true
  matches host/central.Central link/central.Link -> bool:
    if run-failure_: return super host link
    throw "SECURITY_MATCH_FAILED"

class Provider extends providers.Provider:
  radio/fixture.FakeTransport ::= fixture.FakeTransport
  recovery/fixture.FakeTransport ::= fixture.FakeTransport
  opens/int := 0
  owner/Owner
  last/rpc.Session? := null
  constructor run-failure/bool:
    owner = Owner run-failure
    super
  open-transport -> fixture.FakeTransport:
    opens++
    return opens == 1 ? radio : recovery
  create-security-owner host/central.Central link/central.Link info/hci.Capabilities -> security-owner.Owner?:
    return opens == 1 ? owner : null
  run-security-owner owner/security-owner.Owner -> none:
    throw "SECURITY_RUN_FAILED"
  create-session client/int -> rpc.Session:
    last = super client
    return last
